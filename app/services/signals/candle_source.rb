# frozen_string_literal: true

module Signals
  # Where a strategy gets its candles (issue #387).
  #
  # MultiTimeframeSignal used to query ActiveRecord directly, four timeframes
  # per evaluation plus volume/momentum lookups — ~6 queries per step. Live that
  # is fine (one evaluation per tick). In a backtest it is the dominant cost:
  # calibration scaled linearly to ~1hr/symbol for a 60-day 17-candidate grid,
  # and a full year was 6+hrs, which put year-long sweeps out of reach.
  #
  # Rather than fork the strategy for backtests — which would break #297's
  # parity rule, the whole point of replaying the LIVE strategy — the query is
  # made injectable. Live keeps the database source; a backtest preloads the run
  # span once and serves the same reads from memory.
  module CandleSource
    TIMEFRAME_SECONDS = {
      one_minute: 60,
      five_minute: 300,
      fifteen_minute: 900,
      hourly: 3600
    }.freeze

    # The live path, and the default: exactly the query the strategy used to
    # build inline.
    class Database
      def recent(symbol:, timeframe:, limit:, as_of: nil)
        scope = Candle.for_symbol(symbol).public_send(timeframe).order(:timestamp)
        scope = scope.where(timestamp: ..as_of) if as_of
        scope.last(limit)
      end
    end

    # One query per timeframe for a whole run, then binary search per read.
    #
    # The window deliberately starts BEFORE `from`: the strategy needs its
    # warm-up history (80 1h candles by default) to emit anything at the first
    # step, and the database source got that for free by never bounding below.
    # Loading only [from, to] would silently produce a run that emits no signals
    # until the warm-up had accrued inside the window itself.
    class Preloaded
      # Doubled so an incomplete series (gaps, exchange downtime) still reaches
      # the required candle count rather than quietly starving the strategy.
      WARMUP_SAFETY = 2

      def self.for_run(symbol:, from:, to:, warmup_candles:, fallback: Database.new)
        new(symbol: symbol, from: from, to: to, warmup_candles: warmup_candles, fallback: fallback)
      end

      def initialize(symbol:, from:, to:, warmup_candles:, fallback: Database.new)
        @symbol = symbol
        @fallback = fallback
        @series = warmup_candles.to_h do |timeframe, count|
          [timeframe, load_series(timeframe, from, to, count)]
        end
      end

      # Number of rows held in memory, per timeframe — used by specs and worth
      # having when diagnosing a run that ate more memory than expected.
      def loaded_counts
        @series.transform_values(&:size)
      end

      def recent(symbol:, timeframe:, limit:, as_of: nil)
        series = @series[timeframe]
        # Preloading is scoped to one symbol and the timeframes the strategy
        # declared. Anything else falls back to the database rather than
        # returning an empty series that would look like "no data" and silently
        # change the run's behavior.
        return @fallback.recent(symbol: symbol, timeframe: timeframe, limit: limit, as_of: as_of) if
          series.nil? || symbol != @symbol

        return series.last(limit) if as_of.nil?

        upper = upper_bound(series, as_of)
        return [] if upper.zero?

        series[[upper - limit, 0].max...upper]
      end

      private

      def load_series(timeframe, from, to, count)
        seconds = TIMEFRAME_SECONDS.fetch(timeframe, 3600)
        earliest = from - (count.to_i * seconds * WARMUP_SAFETY)

        Candle.for_symbol(@symbol).public_send(timeframe)
          .where(timestamp: earliest..to)
          .order(:timestamp)
          .to_a
      end

      # Count of candles at or before as_of. The series is sorted, so this is a
      # binary search rather than the linear scan a select would do.
      def upper_bound(series, as_of)
        series.bsearch_index { |c| c.timestamp > as_of } || series.size
      end
    end
  end
end
