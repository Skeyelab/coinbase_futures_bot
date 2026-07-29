# frozen_string_literal: true

require "rails_helper"

# Issue #586. freqtrade ships lookahead-analysis because, in their words, "the
# freqtrade backtesting process populates the full dataframe including all
# candle timestamps at the outset" — so a strategy can read data it would not
# have live, and the backtest looks profitable for the wrong reason.
#
# Our engine has the same shape. Signals::CandleSource::Preloaded loads the
# whole run's candles up front and truncates per call via `as_of`. Which means
# the entire protection is one keyword argument:
#
#   return series.last(limit) if as_of.nil?     # <- the tail of EVERYTHING
#
# In a backtest that tail is the FUTURE. All three callers thread as_of today;
# nothing made them. A new indicator, or a refactor that drops the argument,
# reads tomorrow's candles and reports a wonderful edge.
#
# Preloaded is built only by Backtest::Engine (Preloaded.for_run), and a
# backtest always has a current bar, so "give me the latest" is never a
# question it can honestly answer. Live code uses Database, where as_of: nil
# legitimately means now.
RSpec.describe Signals::CandleSource::Preloaded, "refuses to answer without a cutoff (issue #586)" do
  let(:symbol) { "BIP-20DEC30-CDE" }
  let(:from) { Time.utc(2026, 7, 1) }
  let(:to) { Time.utc(2026, 7, 2) }

  before do
    Candle.where(symbol: symbol).delete_all
    # 24 hourly candles, rising, so a future read is obvious in the values.
    24.times do |i|
      price = 60_000.0 + (i * 100)
      Candle.create!(symbol: symbol, timeframe: "1m", timestamp: from + i.hours,
        open: price, high: price, low: price, close: price, volume: 1.0)
    end
  end

  def source
    described_class.for_run(symbol: symbol, from: from, to: to, warmup_candles: {one_minute: 30})
  end

  # The tracer. Silently returning the newest candles is the failure mode; an
  # exception is the only answer that cannot be mistaken for data.
  it "raises rather than returning the newest candles when no cutoff is given" do
    expect { source.recent(symbol: symbol, timeframe: :one_minute, limit: 3) }
      .to raise_error(ArgumentError, /as_of/i)
  end

  # And it must not be possible to get the future by passing nil explicitly,
  # which is what a dropped argument actually looks like at a call site.
  it "raises on an explicit nil cutoff too" do
    expect { source.recent(symbol: symbol, timeframe: :one_minute, limit: 3, as_of: nil) }
      .to raise_error(ArgumentError, /as_of/i)
  end

  # The leak worth naming: Preloaded falls back to the database for a timeframe
  # or symbol it did not preload. If the refusal sat after that branch, a
  # missing cutoff would escape into Database#recent, which answers "now" — in
  # a backtest, the newest candle on disk. The guard has to come first.
  it "refuses before falling back to the database" do
    expect { source.recent(symbol: symbol, timeframe: :hourly, limit: 3) }
      .to raise_error(ArgumentError, /as_of/i)
  end

  it "refuses before falling back for a symbol it never preloaded" do
    expect { source.recent(symbol: "ET-31JUL26-CDE", timeframe: :one_minute, limit: 3) }
      .to raise_error(ArgumentError, /as_of/i)
  end

  # The behaviour that has to keep working: a cutoff returns only what had
  # happened by then.
  it "returns only candles at or before the cutoff" do
    cutoff = from + 5.hours

    candles = source.recent(symbol: symbol, timeframe: :one_minute, limit: 10, as_of: cutoff)

    expect(candles).not_to be_empty
    expect(candles.map(&:timestamp).max).to be <= cutoff
    expect(candles.map { |c| c.close.to_f }.max).to be <= 60_500.0
  end

  # The whole point, stated as the property it protects: what the strategy sees
  # at bar N must not depend on bars after N existing.
  it "gives the same answer whether or not later candles exist" do
    cutoff = from + 5.hours
    early = source.recent(symbol: symbol, timeframe: :one_minute, limit: 10, as_of: cutoff)
      .map { |c| c.close.to_f }

    Candle.where(symbol: symbol).where(timestamp: (from + 6.hours)..).delete_all
    later = source.recent(symbol: symbol, timeframe: :one_minute, limit: 10, as_of: cutoff)
      .map { |c| c.close.to_f }

    expect(early).to eq(later)
  end

  # Live code is not affected: Database#recent answers "now" for a bot that has
  # no future to read.
  describe Signals::CandleSource::Database do
    it "still treats a missing cutoff as now" do
      candles = described_class.new.recent(symbol: "BIP-20DEC30-CDE", timeframe: :one_minute, limit: 3)

      expect(candles.size).to eq(3)
    end
  end
end
