# frozen_string_literal: true

require "rails_helper"

# Issue #606: a one-week BIP backtest produced a single 15-contract trade at a
# $100 assumed notional — $1,500 of exposure for an instrument asset_sizing.yml
# caps at one $659 contract. Per-contract exit thresholds became 15x looser
# and the policy under test could never fire. The backtest harness and live
# sizing must read the same registry or every backtest tests a different bot.
RSpec.describe Backtest::Engine, "sizing parity with asset_sizing.yml (#606)" do
  def strategy_with(quantity:, sl: 60_000.0)
    Class.new do
      define_method(:signal) do |symbol:, equity_usd:, as_of: nil|
        {side: "long", price: 64_000.0, confidence: 90, quantity: quantity,
         sl: sl, tp: 70_000.0}
      end
    end.new
  end

  def silent_strategy
    Class.new do
      def signal(symbol:, equity_usd:, as_of: nil) = nil
    end.new
  end

  it "defaults contract notional from the sizing registry, not $100" do
    e = described_class.new(symbol: "BIP-20DEC30-CDE", strategy: silent_strategy, step: "5m")

    expect(e.contract_size_usd).to eq(659.0)
  end

  it "keeps the $100 shape for an instrument the registry prices there" do
    e = described_class.new(symbol: "BIT-28AUG26-CDE", strategy: silent_strategy, step: "5m")

    expect(e.contract_size_usd).to eq(Trading::AssetSizing.for_product("BIT-28AUG26-CDE").contract_size_usd)
  end

  # The bug this file's first version shipped: the registry sat LAST in the
  # precedence chain, behind the strategy's stale contract_size_usd: 100 (the
  # dead-config class of #605). So BIP still priced at $100 instead of $659,
  # the $0.15 per-contract floor dominated the fee, and a year-long
  # walk-forward measured -17bps/trade when the true-notional figure is
  # -2.7bps. The registry is authoritative (#606 Q1); only an explicit
  # argument outranks it.
  it "prefers the registry over a strategy's own stale contract_size_usd" do
    strategy = Class.new do
      def initialize = @config = {contract_size_usd: 100.0}
      def signal(symbol:, equity_usd:, as_of: nil) = nil
    end.new

    e = described_class.new(symbol: "BIP-20DEC30-CDE", strategy: strategy, step: "5m")

    expect(e.contract_size_usd).to eq(659.0)
  end

  it "falls back to the strategy's value when the registry has no entry for the product" do
    strategy = Class.new do
      def initialize = @config = {contract_size_usd: 42.0}
      def signal(symbol:, equity_usd:, as_of: nil) = nil
    end.new
    allow(Trading::AssetSizing).to receive(:for_product).with("MADE-UP-CDE")
      .and_return(Trading::AssetSizing::Params.new(0.0, 2, 1))

    e = described_class.new(symbol: "MADE-UP-CDE", strategy: strategy, step: "5m")

    expect(e.contract_size_usd).to eq(42.0)
  end

  it "an explicit override still wins" do
    e = described_class.new(symbol: "BIP-20DEC30-CDE", strategy: silent_strategy,
      step: "5m", contract_size_usd: 42.0)

    expect(e.contract_size_usd).to eq(42.0)
  end

  it "clamps an oversized signal to the registry's max_contracts" do
    # First candle opens the position; the second's low trips the stop so the
    # trade closes and is recorded.
    candles = 3.times.map { |i|
      Candle.create!(symbol: "BIP-20DEC30-CDE", timeframe: "5m",
        timestamp: Time.utc(2026, 8, 1, 12, 5 * i), open: 64_000, high: 64_100,
        low: 63_900, close: 64_000, volume: 10)
    }
    engine = described_class.new(symbol: "BIP-20DEC30-CDE",
      strategy: strategy_with(quantity: 15, sl: 63_950.0), step: "5m")

    result = engine.run(from: candles.first.timestamp, to: candles.last.timestamp)

    quantities = result.trades.map { |t| t[:quantity].to_f }
    expect(quantities).not_to be_empty
    # 1 contract x $659 / $64,000 ~= 0.0103 base units. The unclamped 15-contract
    # signal would be ~0.154.
    expect(quantities.max).to be_within(0.002).of(659.0 / 64_000)
  end
end
