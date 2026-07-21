# frozen_string_literal: true

require "rails_helper"

# Backtest support (issue #298): the live strategy must be drivable in an
# event-driven replay without looking into the future and without hitting
# contract resolution.
RSpec.describe Strategy::MultiTimeframeSignal, type: :service do
  def insert_candles(symbol:, base_time:, close: 100.0)
    candle_data = []
    {"1h" => [80, 1.hour], "15m" => [120, 15.minutes], "5m" => [100, 5.minutes], "1m" => [60, 1.minute]}
      .each do |timeframe, (count, step)|
      count.times do |i|
        candle_data << {
          symbol: symbol, timeframe: timeframe, timestamp: base_time - (count - i) * step,
          open: close, high: close + 0.5, low: close - 0.5, close: close, volume: 10,
          created_at: Time.current, updated_at: Time.current
        }
      end
    end
    Candle.insert_all!(candle_data)
  end

  describe "as_of replay bounding" do
    it "never feeds candles after as_of into indicator computation" do
      as_of = Time.parse("2026-01-10T12:00:00Z")
      insert_candles(symbol: "DOGE-USD", base_time: as_of)
      # Future candles with a poisoned price that must not leak into the replay
      Candle.insert_all!([5, 10].map do |mins|
        {symbol: "DOGE-USD", timeframe: "1m", timestamp: as_of + mins.minutes,
         open: 999_999.0, high: 999_999.0, low: 999_999.0, close: 999_999.0, volume: 10,
         created_at: Time.current, updated_at: Time.current}
      end)

      seen_series = []
      allow(Signals::Indicators).to receive(:ema).and_wrap_original do |original, values, period|
        seen_series << values
        original.call(values, period)
      end

      described_class.new(resolve_symbols: false).signal(symbol: "DOGE-USD", as_of: as_of)

      expect(seen_series).not_to be_empty
      expect(seen_series.flatten).not_to include(999_999.0)
    end
  end

  describe "resolve_symbols: false" do
    it "uses the symbol as-is without consulting contract resolution" do
      expect(MarketData::FuturesContractManager).not_to receive(:new)

      described_class.new(resolve_symbols: false).signal(symbol: "BTC-USD")
    end
  end
end
