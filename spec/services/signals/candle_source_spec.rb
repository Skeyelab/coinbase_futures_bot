# frozen_string_literal: true

require "rails_helper"

# Issue #387: the preloaded source exists purely to make backtests affordable.
# It is only worth having if it returns EXACTLY what the database source would
# — a faster backtest that disagrees with live is worse than a slow one
# (#297's parity rule).
RSpec.describe Signals::CandleSource do
  let(:t0) { Time.utc(2026, 6, 1, 0, 0, 0) }
  let(:symbol) { "PRELOAD-TEST" }

  def candle(timeframe, minutes_offset, close)
    Candle.create!(symbol: symbol, timeframe: timeframe, timestamp: t0 + minutes_offset.minutes,
      open: close, high: close, low: close, close: close, volume: 1)
  end

  before do
    (0..119).each { |m| candle("1m", m, 100.0 + m) }
    (0..23).each { |i| candle("5m", i * 5, 200.0 + i) }
    (0..7).each { |i| candle("1h", i * 60, 300.0 + i) }
  end

  let(:database) { described_class::Database.new }
  let(:preloaded) do
    described_class::Preloaded.for_run(symbol: symbol, from: t0 + 1.hour, to: t0 + 2.hours,
      warmup_candles: {hourly: 4, five_minute: 12, one_minute: 60})
  end

  describe "equivalence with the database source" do
    # Sweeps the cursor across the run rather than checking one point: an
    # off-by-one in the binary search would pass a single-point check.
    it "returns identical series at every cursor position and timeframe" do
      [[:one_minute, 30], [:five_minute, 10], [:hourly, 4]].each do |timeframe, limit|
        (60..120).step(7) do |minutes|
          as_of = t0 + minutes.minutes
          from_db = database.recent(symbol: symbol, timeframe: timeframe, limit: limit, as_of: as_of)
          from_mem = preloaded.recent(symbol: symbol, timeframe: timeframe, limit: limit, as_of: as_of)

          expect(from_mem.map(&:timestamp)).to eq(from_db.map(&:timestamp)),
            "mismatch at #{timeframe} as_of=#{as_of}"
          expect(from_mem.map { |c| c.close.to_f }).to eq(from_db.map { |c| c.close.to_f })
        end
      end
    end

    it "excludes candles at or after the cursor exactly as the database does" do
      as_of = t0 + 90.minutes
      series = preloaded.recent(symbol: symbol, timeframe: :one_minute, limit: 200, as_of: as_of)

      expect(series.map(&:timestamp).max).to eq(as_of)
      expect(series.map(&:timestamp)).to all(be <= as_of)
    end
  end

  describe "warm-up window" do
    # The database source never bounded below, so the strategy always had its
    # history. Loading only [from, to] would starve it until the warm-up
    # accrued inside the window itself — a run that silently emits nothing.
    it "loads history from before the run start" do
      earliest = preloaded.recent(symbol: symbol, timeframe: :one_minute, limit: 500,
        as_of: t0 + 2.hours).map(&:timestamp).min

      expect(earliest).to be < (t0 + 1.hour)
    end

    it "serves a full warm-up series at the very first step" do
      as_of = t0 + 1.hour
      expect(preloaded.recent(symbol: symbol, timeframe: :one_minute, limit: 60, as_of: as_of).size)
        .to eq(database.recent(symbol: symbol, timeframe: :one_minute, limit: 60, as_of: as_of).size)
    end
  end

  describe "falling back rather than guessing" do
    it "defers to the database for a symbol it did not preload" do
      Candle.create!(symbol: "OTHER-TEST", timeframe: "1m", timestamp: t0, open: 1, high: 1, low: 1,
        close: 1, volume: 1)

      series = preloaded.recent(symbol: "OTHER-TEST", timeframe: :one_minute, limit: 5, as_of: t0)

      expect(series.size).to eq(1)
    end

    it "defers to the database for a timeframe it did not preload" do
      (0..3).each { |i| candle("15m", i * 15, 400.0 + i) }

      series = preloaded.recent(symbol: symbol, timeframe: :fifteen_minute, limit: 5, as_of: t0 + 1.hour)

      expect(series.size).to eq(4)
    end
  end

  it "reports what it is holding in memory" do
    expect(preloaded.loaded_counts.keys).to match_array(%i[hourly five_minute one_minute])
    expect(preloaded.loaded_counts[:one_minute]).to be_positive
  end
end
