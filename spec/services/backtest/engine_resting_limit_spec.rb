# frozen_string_literal: true

require "rails_helper"

# Issue #568: resting-limit replay mode for maker strategies. In
# fill_model: :through_price the engine quotes off the PREVIOUS bar (the bar
# being replayed can fill the quote, so deriving the quote from it would be
# look-ahead), gives each quote exactly one bar to fill, and cancels it
# otherwise so the next bar re-quotes off fresh data.
RSpec.describe Backtest::Engine, "fill_model: :through_price", type: :service do
  def scripted_strategy(&script)
    Class.new do
      attr_reader :calls

      def initialize(script)
        @script = script || ->(_as_of) {}
        @calls = []
      end

      def signal(symbol:, equity_usd:, as_of: nil)
        @calls << as_of
        @script.call(as_of)
      end
    end.new(script)
  end

  let(:t0) { Time.parse("2026-02-01T00:00:00Z") }

  def insert_step_candles(closes, symbol: "TEST-USD", start: t0, step: 5.minutes, spread: 0.5)
    Candle.insert_all!(closes.each_with_index.map do |close, i|
      {symbol: symbol, timeframe: "5m", timestamp: start + i * step,
       open: close, high: close + spread, low: close - spread, close: close, volume: 10,
       created_at: Time.current, updated_at: Time.current}
    end)
  end

  def engine_for(strategy, **opts)
    described_class.new(symbol: "TEST-USD", strategy: strategy, starting_equity: 10_000.0,
      fill_model: :through_price, maker_fee_rate: 0.0, fee_rate: 0.0003, slippage: 0.0,
      preload_candles: false, **opts)
  end

  it "asks the strategy with the PREVIOUS bar's timestamp and skips the first bar" do
    insert_step_candles(Array.new(5, 100.0))
    strategy = scripted_strategy

    engine_for(strategy).run(from: t0, to: t0 + 4 * 5.minutes)

    expect(strategy.calls).to eq((0..3).map { |i| t0 + i * 5.minutes })
  end

  it "cancels an unfilled quote after its one bar so every flat bar re-quotes" do
    insert_step_candles(Array.new(5, 100.0))
    # Quote far below the lows: never fills.
    strategy = scripted_strategy do |_as_of|
      {side: :long, price: 90.0, quantity: 1.0, tp: 100.0, sl: 85.0, confidence: 50.0}
    end

    engine = engine_for(strategy)
    result = engine.run(from: t0, to: t0 + 4 * 5.minutes)

    # Re-asked on every bar after the first — a stale quote never blocks.
    expect(strategy.calls.size).to eq(4)
    expect(result.trade_count).to eq(0)
  end

  it "fills only when a bar trades through the limit, books maker entry at zero fee" do
    # Bar lows are close - 0.5. Quote at 99.6: bar with close 100.0 has low 99.5
    # which is BELOW the limit -> through-fill at 99.6. TP 100.1 needs a high
    # strictly above it: close 100.0 gives high 100.5 -> maker exit at 100.1.
    insert_step_candles(Array.new(6, 100.0))
    strategy = scripted_strategy do |_as_of|
      {side: :long, price: 99.6, quantity: 1.0, tp: 100.1, sl: 98.0, confidence: 50.0}
    end

    result = engine_for(strategy).run(from: t0, to: t0 + 5 * 5.minutes)

    expect(result.trade_count).to be >= 1
    trade = result.trades.first
    expect(trade[:entry_price]).to eq(99.6)
    expect(trade[:exit_price]).to eq(100.1)
    expect(trade[:fees]).to eq(0.0) # maker both sides at the promo 0% rate
  end

  it "does not fill when bars only touch the limit" do
    # Lows exactly at the quote: touch, never through.
    insert_step_candles(Array.new(5, 100.0))
    strategy = scripted_strategy do |_as_of|
      {side: :long, price: 99.5, quantity: 1.0, tp: 100.0, sl: 98.0, confidence: 50.0}
    end

    result = engine_for(strategy).run(from: t0, to: t0 + 4 * 5.minutes)

    expect(result.trade_count).to eq(0)
  end

  it "leaves the default :touch mode behavior unchanged" do
    insert_step_candles(Array.new(5, 100.0))
    strategy = scripted_strategy do |as_of|
      {side: :long, price: 99.5, quantity: 1.0, tp: 100.4, sl: 98.0, confidence: 50.0} if as_of == t0
    end

    engine = described_class.new(symbol: "TEST-USD", strategy: strategy,
      starting_equity: 10_000.0, fee_rate: 0.0, slippage: 0.0, preload_candles: false)
    result = engine.run(from: t0, to: t0 + 4 * 5.minutes)

    # Touch fill at 99.5 (low == limit) and TP touch at 100.4 (high == tp).
    expect(result.trade_count).to eq(1)
    expect(strategy.calls.first).to eq(t0)
  end
end
