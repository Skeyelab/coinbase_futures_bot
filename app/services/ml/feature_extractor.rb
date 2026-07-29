# frozen_string_literal: true

module Ml
  # Batch feature extraction for the fitted scorer (issue #302 step 2): for
  # every 5m bar in a range, the ~6 inputs the hand-weighted confidence_score
  # consumes — 1h trend strength, 15m/5m EMA alignment, 5m momentum, and the
  # two volume terms — computed as-of that bar with the SAME windows, periods,
  # and EMA math as Strategy::MultiTimeframeSignal (#297 discipline: the
  # features the model trains on must be the features live would compute).
  #
  # No look-ahead, by construction:
  #   * entry is the bar's close, so information available at decision time is
  #     everything CLOSED by bar_ts + 300s;
  #   * a higher-timeframe candle is usable only once its window has closed:
  #     htf_ts + htf_step <= bar_ts + 300;
  #   * all windows end at the bar under evaluation and extend strictly
  #     backward.
  #
  # Documented deviations from the live scorer, both deliberate:
  #   * trend/alignment values are SIGNED where the score takes .abs — live
  #     folds direction into a separate trend gate; a per-direction model
  #     needs the sign as information. The fit decides what it is worth.
  #   * last_price is the 5m close, not the 1m close (they coincide at 5m
  #     boundaries); 1m history is not required, which keeps a year of
  #     extraction at ~150k rows per symbol instead of ~650k.
  #   * a bar with insufficient history is SKIPPED, where live degrades a
  #     sub-score to 0 — a training row must be real, never padded.
  #
  # One array pass per symbol: three ordered candle reads, then pointer walks.
  # No per-bar SQL.
  class FeatureExtractor
    FEATURE_NAMES = %w[trend_1h align_15m align_5m momentum_5m volume_ratio volume_trend].freeze

    # Window sizes and EMA periods pinned to Strategy::MultiTimeframeSignal —
    # a spec asserts they stay equal.
    DEFAULTS = {
      ema_1h_short: 12,
      ema_1h_long: 26,
      ema_15m: 21,
      ema_5m: 13,
      window_1h: 80,
      window_15m: 120,
      window_5m: 100,
      volume_window: 10,
      momentum_window: 8
    }.freeze

    STEP_5M = 300
    STEP_15M = 900
    STEP_1H = 3600
    # How far before `from` candles are read so every window is fillable even
    # across moderate data gaps (live reads last-N with unbounded lookback).
    LOOKBACK_MULTIPLIER = 3

    attr_reader :symbol, :config

    def initialize(symbol:, config: {})
      @symbol = symbol
      @config = DEFAULTS.merge(config)
    end

    # Returns {Time (UTC bar timestamp) => {feature_name => Float}} for every
    # 5m bar in from..to with sufficient history. Bars that cannot fill every
    # window are absent, never padded.
    def features_for_range(from:, to:)
      bars_5m = load_candles("5m", from - lookback(:window_5m, STEP_5M), to)
      bars_15m = load_candles("15m", from - lookback(:window_15m, STEP_15M), to)
      bars_1h = load_candles("1h", from - lookback(:window_1h, STEP_1H), to)

      min_5m_bars = [config[:window_5m], config[:volume_window], config[:momentum_window]].max
      from_epoch = from.to_i
      to_epoch = to.to_i

      features = {}
      usable_15m = 0
      usable_1h = 0

      bars_5m[:ts].each_index do |i|
        ts = bars_5m[:ts][i]
        next if ts < from_epoch
        break if ts > to_epoch

        decision_time = ts + STEP_5M
        usable_15m = advance(bars_15m[:ts], usable_15m, decision_time - STEP_15M)
        usable_1h = advance(bars_1h[:ts], usable_1h, decision_time - STEP_1H)

        next if i + 1 < min_5m_bars
        next if usable_15m < config[:window_15m]
        next if usable_1h < config[:window_1h]

        row = build_row(bars_5m, i, bars_15m, usable_15m, bars_1h, usable_1h)
        features[Time.at(ts).utc] = row if row
      end

      features
    end

    private

    def lookback(window_key, step)
      config[window_key] * step * LOOKBACK_MULTIPLIER
    end

    def load_candles(timeframe, from, to)
      rows = Candle.for_symbol(symbol)
        .where(timeframe: timeframe, timestamp: from..to)
        .order(:timestamp)
        .pluck(:timestamp, :close, :volume)

      {
        ts: rows.map { |ts, _, _| ts.to_i },
        close: rows.map { |_, close, _| close.to_f },
        volume: rows.map { |_, _, volume| volume.to_f }
      }
    end

    # Count of bars whose timestamp <= last_usable_ts; monotone pointer walk,
    # so the whole range costs one pass per timeframe.
    def advance(timestamps, count, last_usable_ts)
      count += 1 while count < timestamps.size && timestamps[count] <= last_usable_ts
      count
    end

    def build_row(bars_5m, i, bars_15m, usable_15m, bars_1h, usable_1h)
      close = bars_5m[:close][i]

      window_1h = bars_1h[:close][usable_1h - config[:window_1h], config[:window_1h]]
      ema1h_short = Signals::Indicators.ema(window_1h, config[:ema_1h_short])
      ema1h_long = Signals::Indicators.ema(window_1h, config[:ema_1h_long])

      window_15m = bars_15m[:close][usable_15m - config[:window_15m], config[:window_15m]]
      ema15 = Signals::Indicators.ema(window_15m, config[:ema_15m])

      window_5m = bars_5m[:close][i + 1 - config[:window_5m], config[:window_5m]]
      ema5 = Signals::Indicators.ema(window_5m, config[:ema_5m])

      return nil if [ema1h_short, ema1h_long, ema15, ema5].any?(&:nil?)

      momentum_window = bars_5m[:close][i + 1 - config[:momentum_window], config[:momentum_window]]
      volume_window = bars_5m[:volume][i + 1 - config[:volume_window], config[:volume_window]]

      {
        "trend_1h" => (ema1h_short - ema1h_long) / [ema1h_long.abs, 1e-9].max,
        "align_15m" => (close - ema15) / [ema15.abs, 1e-9].max,
        "align_5m" => (close - ema5) / [ema5.abs, 1e-9].max,
        # Live's roc_4: last close vs the 4th-from-last of its momentum window.
        "momentum_5m" => (momentum_window.last - momentum_window[-4]) / momentum_window[-4],
        "volume_ratio" => volume_ratio(volume_window),
        # Live's rising/falling factor over the last 3 volumes.
        "volume_trend" => (volume_window.last > volume_window[-3]) ? 1.0 : 0.5
      }
    end

    def volume_ratio(volumes)
      average = volumes.sum / volumes.size
      [volumes.last / [average, 1e-9].max, 3.0].min
    end
  end
end
