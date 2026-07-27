# frozen_string_literal: true

require "rails_helper"

# Issue #387: the strategy issued ~6 candle queries per STEP, so backtest cost
# scaled with window length — ~1hr/symbol for a 60-day 17-candidate grid, 6+hrs
# for a year. Preloading turns that into a handful of queries per RUN.
#
# Two things have to hold, and the second matters more: it must be faster, and
# it must produce the identical run. A quicker backtest that disagrees with the
# live strategy is worse than a slow one (#297 parity).
RSpec.describe Backtest::Engine, "candle preloading" do
  let(:t0) { Time.utc(2026, 6, 1, 0, 0, 0) }
  let(:symbol) { "PRELOAD-ENGINE-TEST" }

  def seed!
    (0..400).each do |m|
      price = 100.0 + Math.sin(m / 9.0) * 5
      Candle.create!(symbol: symbol, timeframe: "1m", timestamp: t0 + m.minutes,
        open: price, high: price + 0.5, low: price - 0.5, close: price, volume: 10)
    end
    [[5, "5m"], [15, "15m"], [60, "1h"]].each do |span, tf|
      (0..(400 / span)).each do |i|
        price = 100.0 + Math.sin(i / 3.0) * 5
        Candle.create!(symbol: symbol, timeframe: tf, timestamp: t0 + (i * span).minutes,
          open: price, high: price + 0.5, low: price - 0.5, close: price, volume: 10)
      end
    end
  end

  def strategy
    Trading::StrategyFactory.multi_timeframe(
      resolve_symbols: false,
      min_1h_candles: 3, min_15m_candles: 3, min_5m_candles: 3, min_1m_candles: 3
    )
  end

  def engine(preload:)
    described_class.new(symbol: symbol, strategy: strategy, step: "5m",
      preload_candles: preload, fee_rate: 0.0, slippage: 0.0)
  end

  def candle_queries
    count = 0
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      count += 1 if payload[:sql]&.include?("candles") && payload[:name] != "SCHEMA"
    end
    yield
    count
  ensure
    ActiveSupport::Notifications.unsubscribe(sub)
  end

  before { seed! }

  it "collapses per-step candle reads into a handful per run" do
    from = t0 + 120.minutes
    to = t0 + 400.minutes

    preloaded_queries = candle_queries { engine(preload: true).run(from: from, to: to) }
    database_queries = candle_queries { engine(preload: false).run(from: from, to: to) }

    expect(preloaded_queries).to be < database_queries
    # The point of the ticket: cost stops scaling with the number of steps.
    expect(preloaded_queries).to be < 20
  end

  # The claim that actually needs guarding.
  it "produces an identical run either way" do
    from = t0 + 120.minutes
    to = t0 + 400.minutes

    with_preload = engine(preload: true).run(from: from, to: to)
    without = engine(preload: false).run(from: from, to: to)

    expect(with_preload.trade_count).to eq(without.trade_count)
    expect(with_preload.total_pnl).to be_within(1e-9).of(without.total_pnl)
    expect(with_preload.total_fees).to be_within(1e-9).of(without.total_fees)
    expect(with_preload.equity_curve).to eq(without.equity_curve)
    expect(with_preload.trades.map { |t| t[:entered_at] }).to eq(without.trades.map { |t| t[:entered_at] })
  end
end
