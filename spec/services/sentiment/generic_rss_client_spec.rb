# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sentiment::GenericRssClient, type: :service do
  def item_for(title, description)
    rss = <<~XML
      <rss><channel><item>
        <title>#{title}</title>
        <link>https://example.com/a</link>
        <pubDate>Mon, 11 Aug 2025 12:00:00 GMT</pubDate>
        <description>#{description}</description>
      </item></channel></rss>
    XML
    REXML::Document.new(rss).elements["rss/channel/item"]
  end

  subject(:client) { described_class.new(url: "https://oilprice.com/rss/main", source_name: "oilprice_rss") }

  it "reports its configured source name" do
    expect(client.source_name).to eq("oilprice_rss")
  end

  it "is always enabled (RSS needs no token)" do
    expect(client).to be_enabled
  end

  it "normalizes an oil article to an OIL-USD event" do
    item = item_for("OPEC output cut lifts crude", "WTI and Brent climb after the decision")

    results = client.send(:normalize_rss_item, item)

    expect(results.map { |r| r[:symbol] }).to include("OIL-USD")
    expect(results.first[:source]).to eq("oilprice_rss")
  end

  it "does not tag symbols outside the source's configured scope" do
    # oilprice_rss is scoped to OIL-USD, so a passing bitcoin mention must not
    # produce a BTC-USD event off an oil feed.
    item = item_for("Crude rises as bitcoin miners chase cheap oil", "WTI up; bitcoin energy use in focus")

    results = client.send(:normalize_rss_item, item)

    symbols = results.map { |r| r[:symbol] }
    expect(symbols).to include("OIL-USD")
    expect(symbols).not_to include("BTC-USD")
  end

  # Issue #433: Trump TRUTH Social posts as a sentiment source. Scoped to the
  # three tradable symbols; the keyword router attributes each post (oil posts ->
  # OIL, crypto -> BTC/ETH, off-topic political posts -> dropped).
  describe "trumpstruth_rss source" do
    subject(:trump) { described_class.new(url: "https://trumpstruth.org/feed", source_name: "trumpstruth_rss") }

    it "is registered and scoped to the tradable symbols" do
      expect(Sentiment::SourceConfig.default.symbols_for("trumpstruth_rss"))
        .to contain_exactly("OIL-USD", "BTC-USD", "ETH-USD")
    end

    it "routes an oil-catalyst post (Houthis/ships/Saudi) to OIL-USD only" do
      item = item_for("Houthi attacks on ships must stop", "Damage to tankers and cargo in the Red Sea; Saudi energy talks continue")
      symbols = trump.send(:normalize_rss_item, item).map { |r| r[:symbol] }
      expect(symbols).to include("OIL-USD")
      expect(symbols).not_to include("BTC-USD", "ETH-USD")
    end

    it "routes a crypto post to BTC-USD" do
      item = item_for("Bitcoin is doing incredibly well", "Crypto and Bitcoin, tremendous")
      symbols = trump.send(:normalize_rss_item, item).map { |r| r[:symbol] }
      expect(symbols).to include("BTC-USD")
    end

    it "drops an off-topic political post (no market keyword)" do
      item = item_for("Thank you to the great people of Ohio", "What a rally, the best ever")
      symbols = trump.send(:normalize_rss_item, item).map { |r| r[:symbol] }
      expect(symbols.compact).to be_empty
    end

    # 51 of the 100 items in the live feed are image-only / re-truth posts that
    # trumpstruth.org serves with a synthesized "[No Title] - Post from <date>"
    # title and an empty "<p></p>" body. They carry no text for the lexicon to
    # score or the router to match, so they can only ever land untagged — 173 of
    # them in 48h, inflating the ingest-rate metric that decides whether the feed
    # is undersampled.
    it "ingests nothing from a contentless post (placeholder title, empty body)" do
      item = item_for("[No Title] - Post from July 28, 2026", "<p></p>")

      expect(trump.send(:normalize_rss_item, item)).to be_empty
    end

    it "still ingests a real post whose body happens to be empty" do
      item = item_for("Houthi attacks on ships must stop", "")

      symbols = trump.send(:normalize_rss_item, item).map { |r| r[:symbol] }
      expect(symbols).to include("OIL-USD")
    end
  end

  # blockworks_rss serves Atom, not RSS 2.0. fetch_recent only walked
  # "rss/channel/item", so the feed matched nothing and the source produced ZERO
  # events for its entire life while reporting itself enabled — the same silent
  # failure #550 removed cryptopanic for, from a different cause.
  describe "an Atom feed" do
    subject(:blockworks) { described_class.new(url: "https://blockworks.co/feed", source_name: "blockworks_rss") }

    let(:atom) do
      <<~XML
        <?xml version="1.0" encoding="utf-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>Blockworks</title>
          <entry>
            <title>Ethereum ETF inflows hit a record</title>
            <link href="https://blockworks.co/news/eth-etf" />
            <updated>2026-07-29T03:32:39.791Z</updated>
            <summary>Ether products drew fresh money this week.</summary>
          </entry>
        </feed>
      XML
    end

    before do
      stub_request(:get, "https://blockworks.co/feed").to_return(status: 200, body: atom)
    end

    it "ingests Atom entries" do
      events = blockworks.fetch_recent

      expect(events.map { |e| e[:symbol] }).to include("ETH-USD")
      expect(events.first).to include(
        source: "blockworks_rss",
        title: "Ethereum ETF inflows hit a record",
        url: "https://blockworks.co/news/eth-etf"
      )
    end

    it "reads the entry's timestamp rather than defaulting to now" do
      expect(blockworks.fetch_recent.first[:published_at])
        .to be_within(1).of(Time.utc(2026, 7, 29, 3, 32, 39))
    end
  end
end
