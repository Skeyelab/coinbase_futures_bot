# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sentiment::BaseNewsClient do
  # Exercise the protected tagging/hashing helpers the way a concrete news
  # client subclass consumes them.
  let(:client_class) do
    Class.new(described_class) do
      def enabled? = true

      def source_name = "test"

      def symbols_in(text) = extract_crypto_symbols(text)

      def hash_for(url, title, symbol = nil) = generate_content_hash(url, title, symbol)

      def parsed_at(str) = parse_timestamp(str)
    end
  end

  subject(:client) { client_class.new }

  describe "#parse_timestamp" do
    it "treats a timezone-less feed date as UTC, regardless of the server's local timezone" do
      # The bug: Time.parse reads a TZ-less string in the SERVER local zone, so on
      # a non-UTC machine (e.g. Eastern) news gets shifted hours into the future and
      # never lands in AggregateSentimentJob's UTC windows.
      ClimateControl.modify(TZ: "America/New_York") do
        expect(client.parsed_at("2026-07-17 19:42:48")).to eq(Time.utc(2026, 7, 17, 19, 42, 48))
      end
    end

    it "honors an explicit timezone offset in the feed date" do
      expect(client.parsed_at("2026-07-17 19:42:48 -0400")).to eq(Time.utc(2026, 7, 17, 23, 42, 48))
    end

    it "falls back to the current time for an unparseable date" do
      expect(client.parsed_at("not a date")).to be_within(5).of(Time.now.utc)
    end
  end

  describe "#extract_crypto_symbols" do
    it "tags oil articles with OIL-USD" do
      expect(client.symbols_in("OPEC output cut lifts crude oil prices")).to include("OIL-USD")
    end

    it "still tags bitcoin articles" do
      expect(client.symbols_in("Bitcoin rallies to new high")).to include("BTC-USD")
    end

    # Issue #431: geopolitical/supply-disruption headlines that move crude but
    # never say "oil/crude" must still route to OIL-USD (the feeds are already
    # oil-scoped; these were being dropped by the commodity-only keyword filter).
    it "tags geopolitical oil catalysts even without a commodity word" do
      [
        "Houthi attacks disrupt Red Sea tanker traffic",
        "Strait of Hormuz tensions escalate as tankers reroute",
        "New Iran sanctions announced by Washington",
        "Refinery outage and pipeline sabotage roil supply",
        "Saudi output decision awaited after supply disruption fears"
      ].each do |headline|
        expect(client.symbols_in(headline)).to include("OIL-USD"), "expected #{headline.inspect} to tag OIL-USD"
      end
    end

    it "does not route these oil catalysts to BTC/ETH" do
      expect(client.symbols_in("Strait of Hormuz tensions escalate")).not_to include("BTC-USD", "ETH-USD")
    end

    it "still ignores an unrelated non-oil headline" do
      expect(client.symbols_in("Local bakery wins small business award")).to eq([nil])
    end
  end

  # A feed marked `exclusive: true` in config/sentiment_sources.yml asserts that
  # every item it publishes is about its one scoped symbol, so a keyword miss is
  # a gap in the keyword list rather than an off-topic article.
  describe "#extract_crypto_symbols on an exclusive source" do
    def client_named(name)
      Class.new(described_class) do
        define_method(:source_name) { name }
        def enabled? = true

        def symbols_in(text) = extract_crypto_symbols(text)
      end.new
    end

    it "tags an exclusive source's article with its scoped symbol even with no keyword hit" do
      # Real discarded rigzone headline: unmistakably oil & gas industry news,
      # but it contains none of the OIL-USD keywords.
      expect(client_named("rigzone_rss").symbols_in("Eni Greenlights Cyprus' First Hydrocarbon Project"))
        .to eq(["OIL-USD"])
    end

    it "leaves a NON-exclusive single-symbol source untagged on a keyword miss" do
      # investing_commodities_rss is scoped [OIL-USD] but is a general commodities
      # feed. Tagging its misses would inject gold and palladium into the OIL-USD
      # baseline as if they were oil sentiment.
      %w[
        Gold\ prices\ slip\ as\ firm\ dollar\ weighs
        UBS\ cuts\ palladium\ price\ target\ on\ oversupply\ concerns
      ].each do |headline|
        expect(client_named("investing_commodities_rss").symbols_in(headline))
          .to eq([nil]), "expected #{headline.inspect} to stay untagged"
      end
    end

    it "still keyword-routes a multi-symbol source rather than tagging every symbol" do
      # coindesk_rss is scoped [BTC-USD, ETH-USD]; tagging both would double-count.
      expect(client_named("coindesk_rss").symbols_in("Ethereum staking yields tick higher"))
        .to eq(["ETH-USD"])
    end
  end

  describe "#generate_content_hash" do
    it "differs per symbol so a multi-symbol article does not collide on upsert" do
      btc = client.hash_for("http://x", "title", "BTC-USD")
      oil = client.hash_for("http://x", "title", "OIL-USD")
      expect(btc).not_to eq(oil)
    end

    it "is stable for the same url, title, and symbol" do
      a = client.hash_for("http://x", "title", "BTC-USD")
      b = client.hash_for("http://x", "title", "BTC-USD")
      expect(a).to eq(b)
    end
  end
end
