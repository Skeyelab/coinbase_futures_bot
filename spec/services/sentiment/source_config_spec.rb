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

  describe ".default" do
    it "loads the shipped config/sentiment_sources.yml" do
      feeds = described_class.default.rss_feeds
      expect(feeds.map { |f| f[:source_name] }).to include("oilprice_rss", "eia_today_in_energy_rss")
    end
  end
end
