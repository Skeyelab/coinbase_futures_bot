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
    # Create 1h candles with a clear uptrend (EMA short > EMA long)
    times = (0...80).map { |i| i.hours.ago }.reverse
    base_price = 100.0
    times.each_with_index do |t, i|
      # Create an uptrend: price increases over time
      price = base_price + (i * 0.5) # 0.5% increase per hour
      Candle.create!(symbol: "BTC-USD-PERP", timeframe: "1h", timestamp: t, open: price, high: price + 1, low: price - 1, close: price, volume: 1)
    end

    # Create 15m candles with pullback and reclaim pattern
    times15 = (0...120).map { |i| i * 15 }.map { |m| m.minutes.ago }.reverse
    times15.each_with_index do |t, i|
      if i < 100
        # Most candles above EMA (uptrend)
        price = base_price + 2.0 + (i * 0.1)
        Candle.create!(symbol: "BTC-USD-PERP", timeframe: "15m", timestamp: t, open: price, high: price + 0.5, low: price - 0.5, close: price, volume: 1)
      else
        # Last few candles show pullback to EMA then reclaim above
        if i == 100
          # Pullback candle - touches EMA (low touches EMA, close below)
          price = base_price + 2.0 + (i * 0.1) # This will be around 102.0
          Candle.create!(symbol: "BTC-USD-PERP", timeframe: "15m", timestamp: t, open: price + 0.5, high: price + 0.5, low: price - 0.1, close: price - 0.2, volume: 1)
        elsif i == 101
          # Reclaim candle - closes above EMA
          price = base_price + 2.0 + (i * 0.1) # This will be around 102.1
          Candle.create!(symbol: "BTC-USD-PERP", timeframe: "15m", timestamp: t, open: price - 0.2, high: price + 0.3, low: price - 0.2, close: price + 0.1, volume: 1)
        elsif i == 102
          # Final candle - well above EMA
          price = base_price + 2.0 + (i * 0.1) # This will be around 102.2
          Candle.create!(symbol: "BTC-USD-PERP", timeframe: "15m", timestamp: t, open: price, high: price + 0.3, low: price - 0.1, close: price + 0.2, volume: 1)
        else
          # Ensure one of the recent candles touches the EMA
          if i == 115
            # This candle should touch the EMA (around 113.06)
            Candle.create!(symbol: "BTC-USD-PERP", timeframe: "15m", timestamp: t, open: 113.5, high: 113.8, low: 113.0, close: 113.2, volume: 1)
          else
            # Other recent candles above EMA
            price = base_price + 2.0 + (i * 0.1)
            Candle.create!(symbol: "BTC-USD-PERP", timeframe: "15m", timestamp: t, open: price, high: price + 0.3, low: price - 0.1, close: price + 0.2, volume: 1)
          end
        end
      end
    end

    SentimentAggregate.create!(symbol: "BTC-USD-PERP", window: "15m", window_end_at: Time.now.utc.change(sec: 0), avg_score: 0.2, z_score: 2.0)

    allow(ENV).to receive(:fetch).with("SENTIMENT_ENABLE", anything).and_return("true")
    allow(ENV).to receive(:fetch).with("SENTIMENT_Z_THRESHOLD", anything).and_return("1.0")

    strat = described_class.new(ema_1h_short: 12, ema_1h_long: 26, ema_15m: 21, min_1h_candles: 80, min_15m_candles: 120)

    order = strat.signal(symbol: "BTC-USD-PERP")

    expect(order).to be_present
    expect(order[:side]).to eq(:buy)
  end
end
