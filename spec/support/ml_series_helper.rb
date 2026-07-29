# frozen_string_literal: true

# Deterministic multi-timeframe candle series for ML specs (issue #302).
# Prices follow a slow sinusoid so every extracted feature has variance;
# volumes cycle so the volume features are non-constant. Bulk-inserted for
# speed — trainer specs need hundreds of bars.
module MlSeriesHelper
  # Small EMA windows so a few hours of synthetic data yields feature rows.
  def tiny_extractor_config
    {
      window_1h: 3, ema_1h_short: 2, ema_1h_long: 3,
      window_15m: 3, ema_15m: 2,
      window_5m: 4, ema_5m: 2,
      volume_window: 3, momentum_window: 4
    }
  end

  def seed_series(symbol, start_at:, hours:, base: 100.0)
    now = Time.current
    rows = []

    (hours * 12).times do |k|
      ts = start_at + k * 300
      close = base * (1.0 + 0.01 * Math.sin(k / 9.0))
      rows << series_row(symbol, "5m", ts, close, 10.0 + (k % 5), now)
    end
    (hours * 4).times do |k|
      ts = start_at + k * 900
      close = base * (1.0 + 0.012 * Math.sin(k / 5.0))
      rows << series_row(symbol, "15m", ts, close, 30.0 + (k % 3), now)
    end
    hours.times do |k|
      ts = start_at + k * 3600
      close = base * (1.0 + 0.015 * Math.sin(k / 3.0))
      rows << series_row(symbol, "1h", ts, close, 120.0, now)
    end

    Candle.insert_all(rows)
  end

  def series_row(symbol, timeframe, ts, close, volume, now)
    {symbol: symbol, timeframe: timeframe, timestamp: ts,
     open: close, high: close * 1.001, low: close * 0.999, close: close,
     volume: volume, created_at: now, updated_at: now}
  end
end

RSpec.configure do |config|
  config.include MlSeriesHelper
end
