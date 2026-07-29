# frozen_string_literal: true

module Labels
  # Path-dependent ("highlow2") label generator — issue #302 step 1.
  #
  # For every bar of a symbol's series, walk FORWARD up to `horizon` bars and
  # decide: did price reach the take-profit (entry * (1 + tp_frac)) BEFORE
  # touching the stop (entry * (1 - sl_frac))? Entry is the bar's close; the
  # entry bar's own extremes never count. Both directions are labeled per bar
  # (short is the exact mirror).
  #
  # Labels:
  #   win        — tp barrier reached before sl within horizon
  #   loss       — sl touched first
  #   unresolved — horizon expired, series ended, or a data gap interrupted
  #                the walk before either barrier resolved
  #
  # Deterministic tie rule (documented decision): when ONE bar spans both
  # barriers (high >= tp AND low <= sl), the label is pessimistically a LOSS.
  # Intrabar ordering is unknowable from OHLC; this is the same stop-before-TP
  # convention as PaperTrading::ExchangeSimulator's intrabar exit pass and the
  # #485 sweep method ("both barriers inside one bar counted as the STOP").
  #
  # Data gaps: the walk requires contiguous bars (timestamp spacing == the
  # timeframe step). A missing bar before resolution yields `unresolved` —
  # we refuse to guess what happened during the gap.
  #
  # Defaults: tp 0.020 / sl 0.012 is the measured #497 200/120 shape.
  # Horizon 288 bars (24h of 5m): the #485 sweep measured the 200/120 race
  # holding ~16.6h on average (~200 five-minute bars), and a 12h window left
  # ~26% of entries unresolved — 24h gives the race room past the typical
  # hold so `unresolved` means genuine indecision, not a clipped window,
  # while keeping the effective-sample arithmetic (span / horizon) honest.
  #
  # Efficiency: one in-memory array pass per symbol — a single ordered candle
  # read, then O(bars x horizon) worst-case scanning with early exit on
  # resolution. No per-bar SQL. Writes are bulk upserts keyed on the shape's
  # unique index, so re-runs are idempotent.
  class PathDependent
    DEFAULT_TP_FRAC = 0.020
    DEFAULT_SL_FRAC = 0.012
    DEFAULT_HORIZON = 288
    DEFAULT_TIMEFRAME = "5m"

    STEP_SECONDS = {"1m" => 60, "5m" => 300, "15m" => 900, "1h" => 3600}.freeze
    UPSERT_SLICE = 10_000

    attr_reader :symbol, :timeframe, :tp_frac, :sl_frac, :horizon

    def initialize(symbol:, timeframe: DEFAULT_TIMEFRAME, tp_frac: DEFAULT_TP_FRAC,
      sl_frac: DEFAULT_SL_FRAC, horizon: DEFAULT_HORIZON)
      raise ArgumentError, "unknown timeframe #{timeframe}" unless STEP_SECONDS.key?(timeframe)
      raise ArgumentError, "horizon must be positive" unless horizon.to_i.positive?
      raise ArgumentError, "tp_frac must be positive" unless tp_frac.to_f.positive?
      raise ArgumentError, "sl_frac must be positive" unless sl_frac.to_f.positive?

      @symbol = symbol
      @timeframe = timeframe
      @tp_frac = tp_frac.to_f
      @sl_frac = sl_frac.to_f
      @horizon = horizon.to_i
    end

    # Labels every bar with timestamp in from..to (both directions) and
    # upserts the rows. Candles are read through to + horizon bars so labels
    # near `to` resolve against real data instead of a clipped window.
    # Returns {bars:, rows_written:}.
    def generate(from:, to:)
      step = STEP_SECONDS.fetch(timeframe)
      candles = Candle.for_symbol(symbol)
        .where(timeframe: timeframe)
        .where(timestamp: from..(to + horizon * step))
        .order(:timestamp)
        .pluck(:timestamp, :high, :low, :close)

      timestamps = candles.map { |ts, _, _, _| ts.to_i }
      highs = candles.map { |_, high, _, _| high.to_f }
      lows = candles.map { |_, _, low, _| low.to_f }
      closes = candles.map { |_, _, _, close| close.to_f }

      now = Time.current
      rows = []
      bars = 0
      to_epoch = to.to_i

      timestamps.each_index do |i|
        break if timestamps[i] > to_epoch

        bars += 1
        long_label, long_bars, short_label, short_bars =
          race(timestamps, highs, lows, closes[i], i, step)

        bar_time = Time.zone.at(timestamps[i])
        rows << build_row(bar_time, "long", long_label, long_bars, now)
        rows << build_row(bar_time, "short", short_label, short_bars, now)
      end

      rows.each_slice(UPSERT_SLICE) do |slice|
        PathDependentLabel.upsert_all(slice, unique_by: PathDependentLabel::SHAPE_KEY_INDEX)
      end

      {bars: bars, rows_written: rows.size}
    end

    private

    # Walk forward from bar i, resolving the long and the short race in one
    # pass. Returns [long_label, long_bars, short_label, short_bars].
    def race(timestamps, highs, lows, entry, i, step)
      long_tp = entry * (1.0 + tp_frac)
      long_sl = entry * (1.0 - sl_frac)
      short_tp = entry * (1.0 - tp_frac)
      short_sl = entry * (1.0 + sl_frac)

      long_label = "unresolved"
      long_bars = nil
      short_label = "unresolved"
      short_bars = nil

      (1..horizon).each do |k|
        j = i + k
        # Series end or data gap: whatever has not resolved stays unresolved.
        break if j >= timestamps.size
        break if timestamps[j] != timestamps[i] + k * step

        high = highs[j]
        low = lows[j]

        if long_label == "unresolved"
          # Stop checked first: a bar spanning both barriers is a loss
          # (pessimistic intrabar ordering — see class comment).
          if low <= long_sl
            long_label = "loss"
            long_bars = k
          elsif high >= long_tp
            long_label = "win"
            long_bars = k
          end
        end

        if short_label == "unresolved"
          if high >= short_sl
            short_label = "loss"
            short_bars = k
          elsif low <= short_tp
            short_label = "win"
            short_bars = k
          end
        end

        break if long_label != "unresolved" && short_label != "unresolved"
      end

      [long_label, long_bars, short_label, short_bars]
    end

    def build_row(bar_time, direction, label, resolved_at_bars, now)
      {
        symbol: symbol,
        timeframe: timeframe,
        bar_timestamp: bar_time,
        tp_frac: tp_frac,
        sl_frac: sl_frac,
        horizon: horizon,
        direction: direction,
        label: label,
        resolved_at_bars: resolved_at_bars,
        created_at: now,
        updated_at: now
      }
    end
  end
end
