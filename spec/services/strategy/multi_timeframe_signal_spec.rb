require "rails_helper"

RSpec.describe Strategy::MultiTimeframeSignal, type: :service do
  before do
    allow(ENV).to receive(:fetch).and_call_original
  end

  it "respects sentiment gate when enabled and z below threshold (no entry)" do
    # Seed minimum candles
    times = (0...120).map { |i| i.hours.ago }.reverse
    times.each { |t| Candle.create!(symbol: "BTC-USD-PERP", timeframe: "1h", timestamp: t, open: 100, high: 100, low: 100, close: 100, volume: 1) }
    times15 = (0...120).map { |i| i * 15 }.map { |m| m.minutes.ago }.reverse
    times15.each { |t| Candle.create!(symbol: "BTC-USD-PERP", timeframe: "15m", timestamp: t, open: 100, high: 100, low: 100, close: 100, volume: 1) }

    # Put price slightly above EMA to trigger a hypothetical long setup
    Candle.last.update!(close: 101)

    # Seed sentiment aggregate with z below threshold
    SentimentAggregate.create!(symbol: "BTC-USD-PERP", window: "15m", window_end_at: Time.now.utc.change(sec: 0), avg_score: 0.1, z_score: 0.5)

    allow(ENV).to receive(:fetch).with("SENTIMENT_ENABLE", anything).and_return("true")
    allow(ENV).to receive(:fetch).with("SENTIMENT_Z_THRESHOLD", anything).and_return("1.0")

    strat = described_class.new(ema_1h_short: 1, ema_1h_long: 1, ema_15m: 1, min_1h_candles: 80, min_15m_candles: 120)
    expect(strat.signal(symbol: "BTC-USD-PERP")).to be_nil
  end

  it "allows entry when z above threshold and sign matches side" do
    # Minimal candles
    times = (0...80).map { |i| i.hours.ago }.reverse
    times.each { |t| Candle.create!(symbol: "BTC-USD-PERP", timeframe: "1h", timestamp: t, open: 100, high: 100, low: 100, close: 101, volume: 1) }
    times15 = (0...120).map { |i| i * 15 }.map { |m| m.minutes.ago }.reverse
    times15.each { |t| Candle.create!(symbol: "BTC-USD-PERP", timeframe: "15m", timestamp: t, open: 100, high: 105, low: 99, close: 102, volume: 1) }

    SentimentAggregate.create!(symbol: "BTC-USD-PERP", window: "15m", window_end_at: Time.now.utc.change(sec: 0), avg_score: 0.2, z_score: 2.0)

    allow(ENV).to receive(:fetch).with("SENTIMENT_ENABLE", anything).and_return("true")
    allow(ENV).to receive(:fetch).with("SENTIMENT_Z_THRESHOLD", anything).and_return("1.0")

    strat = described_class.new(ema_1h_short: 1, ema_1h_long: 1, ema_15m: 1, min_1h_candles: 80, min_15m_candles: 120)
    order = strat.signal(symbol: "BTC-USD-PERP")
    expect(order).to be_present
    expect(order[:side]).to eq(:buy)
  end
end