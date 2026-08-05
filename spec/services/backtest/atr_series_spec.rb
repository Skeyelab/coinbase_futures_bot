# frozen_string_literal: true

require "rails_helper"

RSpec.describe Backtest::AtrSeries do
  # The engine steps at 5m but the live rule reads a 1h ATR, and n8n measured a
  # 2.5x ATR stop varying 16x across timeframes ($17 at 5-min to $273 daily).
  # Computing ATR on the stepping timeframe would test a different rule
  # entirely, so the series is built from 1h bars and sampled at each step.
  def bar(hour, high, low, close)
    Struct.new(:timestamp, :high, :low, :close)
      .new(Time.utc(2026, 8, 1, hour), high, low, close)
  end

  # Ranges are all exactly 2.0, so any window averages to 2.0.
  let(:bars) { (0..5).map { |h| bar(h, 12.0 + h, 10.0 + h, 11.0 + h) } }

  describe "#at" do
    it "has no value before enough bars have closed" do
      series = described_class.new(bars, period: 2)

      expect(series.at(Time.utc(2026, 8, 1, 0, 30))).to be_nil
    end

    # THE LOOKAHEAD TEST. Candle timestamps are bar OPENS. The range of the bar
    # opening at 02:00 is not knowable until 03:00, so at 02:00 -- and at 02:59
    # -- the newest readable ATR is the one ending at the 01:00 bar. Indexing by
    # open instead of close would hand the strategy the volatility of a bar
    # still in progress, and every stop would be set from data the live path
    # could not have had.
    it "will not read a bar that has not closed yet" do
      series = described_class.new(bars, period: 2)

      expect(series.at(Time.utc(2026, 8, 1, 1, 59))).to be_nil
      expect(series.at(Time.utc(2026, 8, 1, 2, 0))).to eq(2.0)
      expect(series.at(Time.utc(2026, 8, 1, 2, 59))).to eq(2.0)
    end

    it "advances only as each further bar closes" do
      series = described_class.new(bars, period: 2)

      # Every range is 2.0, so the VALUE cannot distinguish which bar was used.
      # Count readable points instead: one more becomes available each hour.
      readable = (0..7).map { |h| series.at(Time.utc(2026, 8, 1, h)) }

      expect(readable[0..1]).to all(be_nil)
      expect(readable[2..]).to all(eq(2.0))
    end

    it "holds the last readable value past the end of the series" do
      series = described_class.new(bars, period: 2)

      expect(series.at(Time.utc(2026, 8, 2))).to eq(2.0)
    end

    # A fixture whose ranges are all equal CANNOT detect future data leaking
    # into the window -- every answer is the same number. Volatility has to rise
    # over time for the test to have any power. Early bars range 1, later bars
    # range 20: if the window ever reaches forward, the early ATR jumps.
    it "computes each point from bars available at the time, never later ones" do
      calm = (0..3).map { |h| bar(h, 11.0, 10.0, 10.5) }          # range 1
      storm = (4..7).map { |h| bar(h, 30.0, 10.0, 20.0) }         # range 20
      series = described_class.new(calm + storm, period: 14)

      # Readable at 03:00 uses only the calm bars that have closed.
      expect(series.at(Time.utc(2026, 8, 1, 3))).to be < 3.0
      # By the end the storm has pulled the average up.
      expect(series.at(Time.utc(2026, 8, 1, 8))).to be > 5.0
    end

    it "has nothing to offer from a series too short to form a range" do
      expect(described_class.new([], period: 2).at(Time.utc(2026, 8, 1, 5))).to be_nil
      expect(described_class.new([bars.first], period: 2).at(Time.utc(2026, 8, 1, 5))).to be_nil
    end
  end
end
