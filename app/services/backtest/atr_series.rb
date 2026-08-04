# frozen_string_literal: true

module Backtest
  # A 1h ATR series sampled at the engine's stepping clock.
  #
  # WHY THIS EXISTS AT ALL: the engine steps at 5m, but the live ATR Chandelier
  # reads a ONE_HOUR ATR. The n8n populator measured a 2.5x ATR stop varying
  # 16x across timeframes ($17 at 5-minute to $273 at daily), so computing ATR
  # on the stepping timeframe would not be a tighter version of the rule -- it
  # would be a different rule. The live watcher ticks every 10s against an ATR
  # cached from hourly bars, and this reproduces that shape.
  #
  # LOOKAHEAD: a bar's true range is not knowable until that bar has CLOSED.
  # Candle timestamps are bar OPENS, so the ATR ending at bar N only becomes
  # readable at N.timestamp + the bar duration. Indexing by open would hand the
  # strategy volatility from a bar still in progress -- the same class of defect
  # as issue #586.
  class AtrSeries
    DEFAULT_PERIOD = 14
    DEFAULT_BAR_SECONDS = 3600

    def initialize(bars, period: DEFAULT_PERIOD, bar_seconds: DEFAULT_BAR_SECONDS)
      @period = period
      @bar_seconds = bar_seconds
      @points = build(bars.to_a)
    end

    # The most recent ATR readable at `time`, or nil when none has closed yet.
    def at(time)
      return nil if time.nil? || @points.empty?

      idx = @points.bsearch_index { |p| p[:readable_at] > time }
      last = idx.nil? ? @points.size - 1 : idx - 1
      return nil if last.negative?

      @points[last][:atr]
    end

    private

    def build(bars)
      return [] if bars.size < 2

      bars.each_index.filter_map do |i|
        next if i.zero?

        window = bars[0..i].map { |b| {high: b.high.to_f, low: b.low.to_f, close: b.close.to_f} }
        atr = Signals::Indicators.atr(window, @period)
        next if atr.nil?

        {readable_at: bars[i].timestamp + @bar_seconds, atr: atr}
      end
    end
  end
end
