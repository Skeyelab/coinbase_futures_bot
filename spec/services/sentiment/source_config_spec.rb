# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sentiment::SourceConfig do
  let(:yaml) do
    <<~YAML
      symbols:
        OIL-USD:
          keywords: [OIL, CRUDE, WTI]
          lexicon: oil
      sources:
        oilprice_rss:
          client: rss
          url: https://oilprice.com/rss/main
          symbols: [OIL-USD]
          weight: 1.0
        cryptopanic:
          client: cryptopanic
          weight: 1.0
    YAML
  end

  subject(:config) { described_class.new(YAML.safe_load(yaml)) }

  describe "#symbols_for" do
    it "returns the source's declared symbol scope" do
      expect(config.symbols_for("oilprice_rss")).to eq(["OIL-USD"])
    end

    it "returns nil when a source declares no scope (tags any symbol)" do
      expect(config.symbols_for("cryptopanic")).to be_nil
    end
  end

  describe "#rss_feeds" do
    it "returns only the rss-client sources with url and source name" do
      feeds = config.rss_feeds
      expect(feeds.size).to eq(1)
      expect(feeds.first).to include(source_name: "oilprice_rss", url: "https://oilprice.com/rss/main")
    end
  end

  describe "#symbol_keywords" do
    it "builds a word-boundary matcher per symbol from the configured keywords" do
      matchers = config.symbol_keywords
      expect(matchers["OIL-USD"]).to match("prices for CRUDE rose")
      expect(matchers["OIL-USD"]).not_to match("bitcoin only story")
    end
  end

  describe "#weight_for" do
    it "returns the configured source weight" do
      expect(config.weight_for("oilprice_rss")).to eq(1.0)
    end

    it "defaults to 1.0 for an unknown source" do
      expect(config.weight_for("mystery_feed")).to eq(1.0)
    end
  end

  describe ".default" do
    it "loads the shipped config/sentiment_sources.yml" do
      feeds = described_class.default.rss_feeds
      expect(feeds.map { |f| f[:source_name] }).to include("oilprice_rss", "eia_today_in_energy_rss")
    end

    it "reads a lower weight for the mixed-commodity feed" do
      expect(described_class.default.weight_for("investing_commodities_rss")).to eq(0.7)
    end

    # The trap this guards: `symbols: [OIL-USD]` reads like "this feed only
    # publishes oil", and it is not. Marking a general feed exclusive would inject
    # gold, solar, wheat, and electricity headlines into OIL-USD's z-score
    # baseline as if they were oil sentiment. Each of these was checked against
    # its real recent output before being left non-exclusive.
    it "marks only feeds verified single-topic as exclusive" do
      exclusive = described_class.default.sources.keys
        .select { |s| described_class.default.exclusive_symbol_for(s) }

      expect(exclusive).to eq(["rigzone_rss"])
    end

    it "does not treat a single-symbol scope as an exclusivity claim" do
      %w[oilprice_rss eia_today_in_energy_rss investing_commodities_rss].each do |source|
        expect(described_class.default.symbols_for(source)).to eq(["OIL-USD"])
        expect(described_class.default.exclusive_symbol_for(source))
          .to be_nil, "#{source} publishes more than oil and must not be exclusive"
      end
    end
  end

  describe "#exclusive_symbol_for" do
    let(:yaml) do
      <<~YAML
        symbols:
          OIL-USD: {keywords: [OIL], lexicon: oil}
          BTC-USD: {keywords: [BTC], lexicon: crypto}
          ETH-USD: {keywords: [ETH], lexicon: crypto}
        sources:
          rigzone_rss: {client: rss, symbols: [OIL-USD], exclusive: true}
          oilprice_rss: {client: rss, symbols: [OIL-USD]}
          coindesk_rss: {client: coindesk, symbols: [BTC-USD, ETH-USD], exclusive: true}
          unscoped_rss: {client: rss, exclusive: true}
      YAML
    end

    it "returns the scoped symbol for an exclusive single-symbol source" do
      expect(config.exclusive_symbol_for("rigzone_rss")).to eq("OIL-USD")
    end

    it "returns nil when the source does not declare exclusive" do
      expect(config.exclusive_symbol_for("oilprice_rss")).to be_nil
    end

    # There is no way to pick which of two symbols a keyword-less article is
    # about, and tagging both double-counts one article across two z-scores.
    it "refuses exclusivity on a multi-symbol source" do
      expect(config.exclusive_symbol_for("coindesk_rss")).to be_nil
    end

    it "refuses exclusivity on an unscoped source" do
      expect(config.exclusive_symbol_for("unscoped_rss")).to be_nil
    end

    it "returns nil for an unknown source" do
      expect(config.exclusive_symbol_for("mystery_feed")).to be_nil
    end
  end
end
