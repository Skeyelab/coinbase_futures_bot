require "rails_helper"

# Acceptance for issue #297: live (MultiTimeframeSignal) and
# backtest/calibration (Pullback1h) paths must compute identical indicator
# values on identical input. Both are proven to route through the single
# shared implementation in Signals::Indicators.
RSpec.describe "Strategy indicator parity", type: :service do
  it "no strategy class retains its own EMA implementation" do
    [Strategy::MultiTimeframeSignal, Strategy::Pullback1h].each do |klass|
      own_methods = klass.instance_methods(false) + klass.private_instance_methods(false)
      expect(own_methods).not_to include(:ema), "#{klass} still defines a private #ema"
    end
  end

  describe "routing through Signals::Indicators" do
    before { allow(Signals::Indicators).to receive(:ema).and_call_original }

    it "Pullback1h computes its EMAs via the shared module" do
      stub_candle = Struct.new(:close, :low, :high, :volume, :timestamp)
      closes = Array.new(60) { |i| 100.0 + i * 0.5 }
      candles = closes.map { |c| stub_candle.new(c, c - 1.0, c + 1.0, 10.0, Time.current) }

      Strategy::Pullback1h.new.signal(candles: candles, symbol: "DOGE-USD")

      expect(Signals::Indicators).to have_received(:ema).with(closes, 12)
      expect(Signals::Indicators).to have_received(:ema).with(closes, 50)
    end

    it "MultiTimeframeSignal computes its EMAs via the shared module" do
      base_time = Time.parse("2025-08-27T12:00:00Z")
      candle_data = []
      {"1h" => [80, 1.hour], "15m" => [120, 15.minutes], "5m" => [100, 5.minutes], "1m" => [60, 1.minute]}
        .each do |timeframe, (count, step)|
        count.times do |i|
          price = 100.0 + i * 0.1
          candle_data << {
            symbol: "DOGE-USD", timeframe: timeframe, timestamp: base_time - (count - i) * step,
            open: price, high: price + 0.5, low: price - 0.5, close: price, volume: 10,
            created_at: Time.current, updated_at: Time.current
          }
        end
      end
      Candle.insert_all!(candle_data)

      strategy = Strategy::MultiTimeframeSignal.new
      strategy.signal(symbol: "DOGE-USD")

      closes_1h = Candle.for_symbol("DOGE-USD").hourly.order(:timestamp).last(80).map { |c| c.close.to_f }
      expect(Signals::Indicators).to have_received(:ema).with(closes_1h, 12)
      expect(Signals::Indicators).to have_received(:ema).with(closes_1h, 26)
    end
  end

  it "both strategies see identical EMA values for an identical input series" do
    series = Array.new(80) { |i| 50_000.0 + i * 25 + Math.sin(i * 0.3) * 100 }
    [12, 26, 50].each do |period|
      expect(Signals::Indicators.ema(series, period))
        .to eq(Signals::Indicators.ema(series.dup, period))
    end
  end
end
