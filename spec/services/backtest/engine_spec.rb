# frozen_string_literal: true

require "rails_helper"

RSpec.describe Backtest::Engine, type: :service do
  # Deterministic stand-in strategy: emits a scripted signal per as_of.
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

  def insert_step_candles(closes, symbol: "TEST-USD", start: t0, step: 5.minutes)
    Candle.insert_all!(closes.each_with_index.map do |close, i|
      {symbol: symbol, timeframe: "5m", timestamp: start + i * step,
       open: close, high: close + 0.5, low: close - 0.5, close: close, volume: 10,
       created_at: Time.current, updated_at: Time.current}
    end)
  end

  describe "event-driven replay mechanics" do
    it "produces the expected trade and PnL for a known price series (no randomness)" do
      closes = Array.new(10, 100.0) + (1..10).map { |i| 100.0 + i }
      insert_step_candles(closes)

      strategy = scripted_strategy do |as_of|
        if as_of == t0
          {side: :long, price: 100.0, quantity: 1.0, tp: 105.0, sl: 95.0, confidence: 50.0}
        end
      end

      engine = described_class.new(symbol: "TEST-USD", strategy: strategy,
        starting_equity: 10_000.0, fee_rate: 0.001, slippage: 0.0)
      result = engine.run(from: t0, to: t0 + 19 * 5.minutes)

      expect(result).to be_a(Backtest::Result)
      expect(result.trade_count).to eq(1)

      trade = result.trades.first
      # entry 100 (fee 0.1), exit at TP 105 (fee 0.105): pnl = 5 - 0.205
      expect(trade[:side]).to eq(:long)
      expect(trade[:pnl]).to be_within(1e-9).of(4.795)
      expect(trade[:fees]).to be_within(1e-9).of(0.205)
      expect(trade[:entered_at]).to eq(t0)
      # TP 105 first reachable on the candle whose high (close+0.5) >= 105: close 104.6? closes hit 105 at i=14 (high 105.5); i=14 -> t0 + 14*5min
      expect(trade[:exited_at]).to eq(t0 + 14 * 5.minutes)
      expect(result.final_equity).to be_within(1e-9).of(10_004.795)
    end

    it "drives the strategy once per step candle with as_of, skipping steps while a position is open" do
      closes = Array.new(10, 100.0) + (1..10).map { |i| 100.0 + i }
      insert_step_candles(closes)

      strategy = scripted_strategy do |as_of|
        if as_of == t0
          {side: :long, price: 100.0, quantity: 1.0, tp: 105.0, sl: 95.0, confidence: 50.0}
        end
      end

      engine = described_class.new(symbol: "TEST-USD", strategy: strategy,
        starting_equity: 10_000.0, fee_rate: 0.0, slippage: 0.0)
      engine.run(from: t0, to: t0 + 19 * 5.minutes)

      # Called at t0 (opens trade), silent while position open (steps 1..14),
      # then called again on every flat step (15..19).
      expect(strategy.calls.first).to eq(t0)
      expect(strategy.calls).to eq([t0] + (15..19).map { |i| t0 + i * 5.minutes })
    end

    it "returns an empty result when there are no candles" do
      engine = described_class.new(symbol: "EMPTY-USD", strategy: scripted_strategy,
        starting_equity: 10_000.0)
      result = engine.run(from: t0, to: t0 + 1.hour)

      expect(result.trade_count).to eq(0)
      expect(result.final_equity).to eq(10_000.0)
    end
  end

  describe "defaults" do
    it "runs the live strategy (MultiTimeframeSignal) with symbol resolution off" do
      engine = described_class.new(symbol: "TEST-USD")
      expect(engine.strategy).to be_a(Strategy::MultiTimeframeSignal)
      expect(engine.strategy.instance_variable_get(:@config)[:resolve_symbols]).to be(false)
    end
  end

  describe "integration with the live strategy" do
    before do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("SENTIMENT_ENABLE", anything).and_return("false")
    end

    it "exercises MultiTimeframeSignal via the shared indicators and completes trades on a strong trend" do
      t_end = Time.parse("2026-02-10T00:00:00Z")
      rate_per_min = 0.01
      price_at = ->(ts) { 100.0 + (ts - (t_end - 90.hours)) / 60.0 * rate_per_min }

      candle_data = []
      {"1h" => [95, 1.hour], "15m" => [140, 15.minutes], "5m" => [130, 5.minutes], "1m" => [420, 1.minute]}
        .each do |timeframe, (count, step)|
        count.times do |i|
          ts = t_end - (count - 1 - i) * step
          close = price_at.call(ts)
          candle_data << {
            symbol: "TREND-USD", timeframe: timeframe, timestamp: ts,
            open: close - 0.1, high: close + 0.5, low: close - 0.5, close: close, volume: 10 + i,
            created_at: Time.current, updated_at: Time.current
          }
        end
      end
      Candle.insert_all!(candle_data)

      engine = described_class.new(symbol: "TREND-USD", starting_equity: 10_000.0,
        fee_rate: 0.0015, slippage: 0.0002)

      allow(engine.strategy).to receive(:signal).and_call_original
      result = engine.run(from: t_end - 300.minutes, to: t_end)

      expect(engine.strategy).to have_received(:signal).at_least(:once) do |symbol:, as_of:, **|
        expect(symbol).to eq("TREND-USD")
        expect(as_of).to be_a(Time)
      end
      expect(result.trade_count).to be >= 1
      expect(result.trades).to all(include(side: :long))
    end
  end
end
