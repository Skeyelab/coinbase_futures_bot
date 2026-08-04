# frozen_string_literal: true

module Signals
  # Shared, pure indicator math used by every strategy, backtest, and
  # calibration path (issue #297). No DB access, deterministic:
  # same input series always produces the same output.
  #
  # Canonical EMA convention (documented decision):
  #   Seed with the SMA of the first `period` values, then apply the
  #   recursive smoothing (k = 2 / (period + 1)) to the remaining values.
  #   This is the TA-Lib / TradingView standard, so our values can be
  #   verified against external tooling and charting. It requires at
  #   least `period` values; callers with fewer get nil, never a guess.
  module Indicators
    module_function

    # Average true range over the last `period` bars.
    #
    # Wilder's TRUE RANGE, then a SIMPLE MEAN -- deliberately not Wilder's
    # smoothing. This mirrors the n8n Market Data Populator, which is what the
    # live ATR Chandelier stop is measured against. A textbook Wilder EMA here
    # would produce a different number and quietly compare the backtest to a
    # rule nobody is running.
    #
    # Candles are hashes with :high, :low, :close, oldest first. Returns a
    # Float, or nil when there are too few bars to form even one range.
    def atr(candles, period)
      return nil if period.to_i < 1
      return nil if candles.nil?

      ranges = true_ranges(candles)
      return nil if ranges.empty?

      window = ranges.last(period)
      window.sum / window.size.to_f
    end

    # One true range per bar after the first. The previous CLOSE is what makes a
    # gap count: an overnight jump is risk you were exposed to holding through
    # the close, so it belongs in the volatility measure.
    def true_ranges(candles)
      candles.each_cons(2).map do |prev, cur|
        high = cur[:high].to_f
        low = cur[:low].to_f
        prev_close = prev[:close].to_f

        # The .abs on the high term can never change the result -- high >= low,
        # so on a gap up both differences are positive and on a gap down the low
        # term is always the larger magnitude. It stays because this is the
        # canonical true-range formula and is character-for-character what the
        # n8n populator runs; parity is worth more here than dropping a term a
        # reader would expect to see.
        [high - low, (high - prev_close).abs, (low - prev_close).abs].max
      end
    end

    # Exponential moving average over the full series.
    # Returns a Float, or nil when period is non-positive or the series
    # is shorter than period.
    def ema(values, period)
      period = period.to_i
      return nil if period <= 0

      series = values.map(&:to_f)
      return nil if series.size < period

      k = 2.0 / (period + 1)
      seed = series.first(period).sum / period
      series.drop(period).reduce(seed) { |acc, v| v * k + acc * (1 - k) }
    end

    # Sample standard deviation (n-1 denominator) of the last `period` values.
    # Returns a Float, or nil when period < 2 (sample variance is undefined)
    # or the series is shorter than period.
    def stddev(values, period)
      period = period.to_i
      return nil if period < 2

      series = values.map(&:to_f)
      return nil if series.size < period

      window = series.last(period)
      mean = window.sum / period
      Math.sqrt(window.sum { |v| (v - mean)**2 } / (period - 1))
    end

    # Simple moving average of the last `period` values.
    # Returns a Float, or nil when period is non-positive or the series
    # is shorter than period.
    def sma(values, period)
      period = period.to_i
      return nil if period <= 0

      series = values.map(&:to_f)
      return nil if series.size < period

      series.last(period).sum / period
    end
  end
end
