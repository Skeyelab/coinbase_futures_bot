# frozen_string_literal: true

module Sentiment
  # Snapshot is a read-only query object summarizing sentiment pipeline health
  # for the TUI Health tab, system strip, and `bin/futuresbot status`. It only
  # reads (never writes), so it is safe to call on every TUI tick.
  class Snapshot
    DEFAULT_WINDOW = "15m"
    DEFAULT_STALE_MINUTES = 30

    SymbolSnapshot = Struct.new(:symbol, :z_score, :event_count, :window, :window_end_at)

    Result = Struct.new(:symbols, :last_event_at, :last_aggregate_at, :sources, :stale) do
      def stale? = stale
    end

    def initialize(symbols: nil, window: DEFAULT_WINDOW, stale_after: nil, now: Time.current, aggregator: nil)
      @symbols = symbols || default_symbols
      @window = window
      @stale_after = stale_after || default_stale_after
      @now = now
      @aggregator = aggregator || MultiSourceAggregator.new
    end

    def call
      last_event_at = SentimentEvent.maximum(:published_at)

      Result.new(
        @symbols.map { |sym| symbol_snapshot(sym) },
        last_event_at,
        SentimentAggregate.maximum(:window_end_at),
        source_health,
        stale?(last_event_at)
      )
    end

    private

    def source_health
      @aggregator.source_status.map { |s| {name: s[:name], enabled: s[:enabled]} }
    end

    def default_symbols
      ContractSymbolMapper.sentiment_symbols_for_enabled_contracts
    end

    def stale?(last_event_at)
      last_event_at.nil? || last_event_at < @now - @stale_after
    end

    def default_stale_after
      minutes = ENV.fetch("SENTIMENT_STALE_THRESHOLD_MINUTES", DEFAULT_STALE_MINUTES).to_i
      minutes.minutes
    end

    def symbol_snapshot(symbol)
      agg = SentimentAggregate
        .for_symbol(symbol)
        .for_window(@window)
        .order(window_end_at: :desc)
        .first

      SymbolSnapshot.new(
        symbol,
        agg&.z_score&.to_f,
        agg&.count,
        @window,
        agg&.window_end_at
      )
    end
  end
end
