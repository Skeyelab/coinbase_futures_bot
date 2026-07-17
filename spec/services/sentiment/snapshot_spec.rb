# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sentiment::Snapshot do
  let(:now) { Time.utc(2026, 7, 17, 12, 0, 0) }

  describe "per-symbol data" do
    it "returns the latest 15m aggregate z-score, event count, and window_end_at for a symbol" do
      SentimentAggregate.create!(symbol: "OIL-USD", window: "15m", window_end_at: now - 30.minutes,
        count: 1, avg_score: 0.1, z_score: 0.9)
      latest = SentimentAggregate.create!(symbol: "OIL-USD", window: "15m", window_end_at: now - 15.minutes,
        count: 3, avg_score: -0.2, z_score: -0.4)

      result = described_class.new(symbols: ["OIL-USD"], now: now).call
      oil = result.symbols.find { |s| s.symbol == "OIL-USD" }

      expect(oil.z_score).to eq(-0.4)
      expect(oil.event_count).to eq(3)
      expect(oil.window_end_at).to eq(latest.window_end_at)
      expect(oil.window).to eq("15m")
    end

    it "returns nil metrics for a symbol with no aggregates" do
      result = described_class.new(symbols: ["OIL-USD"], now: now).call
      oil = result.symbols.find { |s| s.symbol == "OIL-USD" }

      expect(oil.z_score).to be_nil
      expect(oil.event_count).to be_nil
      expect(oil.window_end_at).to be_nil
    end
  end

  describe "pipeline meta" do
    it "reports the most recent event and aggregate timestamps" do
      SentimentEvent.create!(source: "coindesk", symbol: "OIL-USD", published_at: now - 40.minutes,
        raw_text_hash: "a", title: "old")
      newest_event = SentimentEvent.create!(source: "coindesk", symbol: "OIL-USD", published_at: now - 5.minutes,
        raw_text_hash: "b", title: "fresh")
      newest_agg = SentimentAggregate.create!(symbol: "OIL-USD", window: "15m", window_end_at: now - 15.minutes,
        count: 3, avg_score: -0.2, z_score: -0.4)

      result = described_class.new(symbols: ["OIL-USD"], now: now).call

      expect(result.last_event_at).to eq(newest_event.published_at)
      expect(result.last_aggregate_at).to eq(newest_agg.window_end_at)
    end

    it "is not stale when an event exists within the threshold" do
      SentimentEvent.create!(source: "coindesk", symbol: "OIL-USD", published_at: now - 10.minutes,
        raw_text_hash: "c", title: "fresh")

      result = described_class.new(symbols: ["OIL-USD"], now: now, stale_after: 30.minutes).call

      expect(result.stale?).to be(false)
    end

    it "is stale when the newest event is older than the threshold" do
      SentimentEvent.create!(source: "coindesk", symbol: "OIL-USD", published_at: now - 45.minutes,
        raw_text_hash: "d", title: "stale")

      result = described_class.new(symbols: ["OIL-USD"], now: now, stale_after: 30.minutes).call

      expect(result.stale?).to be(true)
    end

    it "is stale when no events exist at all" do
      result = described_class.new(symbols: ["OIL-USD"], now: now, stale_after: 30.minutes).call

      expect(result.stale?).to be(true)
    end
  end

  describe "source health" do
    it "reflects enabled/disabled clients from the aggregator's source_status" do
      aggregator = instance_double(Sentiment::MultiSourceAggregator, source_status: [
        {name: "CoinDesk", enabled: true, class: "Sentiment::CoindeskRssClient"},
        {name: "CryptoPanic", enabled: false, class: "Sentiment::CryptoPanicClient"}
      ])

      result = described_class.new(symbols: ["OIL-USD"], now: now, aggregator: aggregator).call

      expect(result.sources).to contain_exactly(
        {name: "CoinDesk", enabled: true},
        {name: "CryptoPanic", enabled: false}
      )
    end
  end

  describe "default symbols" do
    it "falls back to the sentiment symbols for enabled contracts when none are given" do
      allow(Sentiment::ContractSymbolMapper).to receive(:sentiment_symbols_for_enabled_contracts)
        .and_return(["OIL-USD"])
      SentimentAggregate.create!(symbol: "OIL-USD", window: "15m", window_end_at: now - 15.minutes,
        count: 2, avg_score: 0.1, z_score: 0.5)

      result = described_class.new(now: now).call

      expect(result.symbols.map(&:symbol)).to eq(["OIL-USD"])
    end
  end
end
