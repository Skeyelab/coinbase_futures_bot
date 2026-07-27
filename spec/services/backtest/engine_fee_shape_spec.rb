# frozen_string_literal: true

require "rails_helper"

# Issue #471: the engine used to keep only CostModel.fee_for[:taker_rate] and
# discard :per_contract_fee, so every backtest was priced as pure proportional
# bps. The floor is not a rounding detail — on a small-notional contract it is
# the dominant cost term, which is the structural expense ADR 0002 found when
# taker costs consumed the edge.
RSpec.describe Backtest::Engine, "venue fee shape" do
  def silent_strategy
    Class.new do
      def signal(symbol:, equity_usd:, as_of: nil) = nil
    end.new
  end

  def engine_for(symbol, **overrides)
    described_class.new(symbol: symbol, strategy: silent_strategy, step: "5m", **overrides)
  end

  # CostModel.perp?(symbol) is true iff snapshotted FundingRate rows exist,
  # reusing the #457 signal — so a dated contract is simply one with none.
  def make_perp(symbol)
    FundingRate.create!(product_id: symbol, funding_time: 1.hour.ago, funding_rate: 0.000014,
      funding_interval_seconds: 3600, observed_at: 1.hour.ago)
  end

  it "carries the dated per-contract floor for a contract with no funding history" do
    e = engine_for("NOL-19AUG26-CDE")

    expect(e.fee_rate).to eq(CostModel.dated_taker_rate)
    expect(e.per_contract_fee).to eq(CostModel.dated_fee_per_contract)
  end

  it "carries the perp floor for a product Coinbase advertises funding on" do
    make_perp("BIP-PERP-TEST")
    e = engine_for("BIP-PERP-TEST")

    expect(e.fee_rate).to eq(CostModel.taker_fee_rate)
    expect(e.per_contract_fee).to eq(CostModel.min_fee_per_contract)
  end

  # An explicit override replaces the venue model wholesale. Passing
  # fee_rate: 0.0 to isolate PnL mechanics has to mean zero fees — not "zero
  # rate but still pay the floor", which would make a deliberate zero silently
  # non-zero.
  it "drops the floor when the caller overrides the rate" do
    expect(engine_for("NOL-19AUG26-CDE", fee_rate: 0.0).per_contract_fee).to be_nil
    expect(engine_for("NOL-19AUG26-CDE", fee_rate: 0.001).per_contract_fee).to be_nil
  end

  it "lets a caller express a floor alongside a custom rate" do
    e = engine_for("NOL-19AUG26-CDE", fee_rate: 0.001, per_contract_fee: 2.50)

    expect(e.fee_rate).to eq(0.001)
    expect(e.per_contract_fee).to eq(2.50)
  end

  # Issue #459: the break-even gate authorizes a trade; the simulated fill pays
  # for it. If they price different fees the run is incoherent — the gate can
  # wave through trades the fills then lose money on, or refuse trades that
  # would clear.
  describe "gate and fill agree on price" do
    # The real MultiTimeframeSignal, not the silent stub: this is about what
    # the strategy's own break-even config ends up holding.
    def real_engine_for(symbol, **overrides)
      described_class.new(symbol: symbol, step: "5m", **overrides)
    end

    def strategy_fee_rate(engine)
      engine.strategy.instance_variable_get(:@config)[:fee_rate]
    end

    it "pins the strategy's break-even rate to what the engine charges" do
      e = real_engine_for("NOL-19AUG26-CDE", contract_size_usd: 930.0)
      e.run(from: Time.utc(2026, 6, 1), to: Time.utc(2026, 6, 2))

      expect(strategy_fee_rate(e)).to eq(e.send(:break_even_fee_rate))
    end

    it "folds the per-contract floor in when it dominates the rate" do
      e = real_engine_for("NOL-19AUG26-CDE", contract_size_usd: 100.0)

      # $0.85 on a $100 contract is 85 bps, far above the 9 bps dated rate.
      expect(e.send(:break_even_fee_rate)).to be_within(1e-9).of(CostModel.dated_fee_per_contract / 100.0)
    end

    it "carries an explicit fee override through to the gate" do
      e = real_engine_for("NOL-19AUG26-CDE", fee_rate: 0.0015, contract_size_usd: 100.0)
      e.run(from: Time.utc(2026, 6, 1), to: Time.utc(2026, 6, 2))

      # #471: an explicit rate replaces the venue model wholesale, floor included.
      expect(e.send(:break_even_fee_rate)).to eq(0.0015)
      expect(strategy_fee_rate(e)).to eq(0.0015)
    end
  end
end
