# frozen_string_literal: true

require "rails_helper"

# Forward measurement harness (follow-up to #431–#434): does a symbol's sentiment
# z-score at time t predict the price return over t -> t+horizon? Joins
# SentimentAggregate z-scores to forward Candle returns and reports correlation +
# directional hit-rate. Meaningful once weeks of data accumulate; runnable anytime.
RSpec.describe Sentiment::PredictivenessStudy, type: :service do
  let(:t0) { Time.utc(2026, 8, 1, 0, 0, 0) }

  def candle(hour, close, symbol: "NOL-TEST")
    Candle.create!(symbol: symbol, timeframe: "1h", timestamp: t0 + hour.hours,
      open: close, high: close, low: close, close: close, volume: 1)
  end

  def agg(hour, z, symbol: "OIL-USD-TEST")
    SentimentAggregate.create!(symbol: symbol, window: "1h", window_end_at: t0 + hour.hours,
      z_score: z, avg_score: 0, weighted_score: 0, count: 3)
  end

  subject(:study) do
    described_class.new(sentiment_symbol: "OIL-USD-TEST", price_symbol: "NOL-TEST",
      window: "1h", horizon_hours: 1, z_threshold: 1.0)
  end

  context "when sentiment perfectly predicts the next-hour move" do
    before do
      [[0, 100.0], [1, 101.0], [2, 100.0], [3, 99.0], [4, 100.0], [5, 101.0]].each { |h, p| candle(h, p) }
      # z sign matches the next hour's direction at each point
      [[0, 2.0], [1, -2.0], [2, -2.0], [3, 2.0], [4, 2.0]].each { |h, z| agg(h, z) }
    end

    it "reports a strong positive correlation and perfect directional hit-rate" do
      r = study.run(from: t0, to: t0 + 5.hours)

      expect(r[:n]).to eq(5)
      expect(r[:correlation]).to be > 0.9
      expect(r[:signal_count]).to eq(5) # all |z| >= 1.0
      expect(r[:hit_rate]).to eq(1.0)
      expect(r[:horizon_hours]).to eq(1)
    end
  end

  it "skips aggregates with no forward price and reports n=0 cleanly" do
    agg(0, 2.0) # no candles at all
    r = study.run(from: t0, to: t0 + 2.hours)
    expect(r[:n]).to eq(0)
    expect(r[:correlation]).to be_nil
    expect(r[:hit_rate]).to be_nil
  end

  it "counts a wrong-direction signal against the hit-rate" do
    candle(0, 100.0)
    candle(1, 99.0)   # price fell
    agg(0, 2.0)       # but sentiment was bullish -> a miss
    r = study.run(from: t0, to: t0 + 1.hour)
    expect(r[:n]).to eq(1)
    expect(r[:hit_rate]).to eq(0.0)
  end
end
