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
  end
end
