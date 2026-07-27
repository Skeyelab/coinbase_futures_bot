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
end
