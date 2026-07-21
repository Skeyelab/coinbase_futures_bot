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
