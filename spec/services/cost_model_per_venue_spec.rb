# frozen_string_literal: true

require "rails_helper"

# Issue #459: the live cost gates priced every symbol at the global perp taker
# rate. Oil trades dated NOL — 9 bps with a $0.85/contract floor, not 3 bps with
# a $0.15 floor — so break-even and net-of-costs were understated on the one
# asset actually being traded.
RSpec.describe CostModel, "per-venue live pricing" do
  let(:dated) { "NOL-19AUG26-CDE" }
  let(:perp) { "BIP-PERP-TEST" }

  # perp?(symbol) is true iff snapshotted FundingRate rows exist (#457).
  before do
    FundingRate.create!(product_id: perp, funding_time: 1.hour.ago, funding_rate: 0.000014,
      funding_interval_seconds: 3600, observed_at: 1.hour.ago)
  end

  describe ".effective_taker_rate" do
    # A per-contract dollar floor is a RATE once you know what a contract is
    # worth: floor / notional. Expressing it that way lets the break-even gate,
    # which reasons in prices, price the floor at all.
    it "converts the per-contract floor into a rate when it dominates" do
      # $0.85 on a $100 contract is 85 bps — far above the 9 bps dated rate.
      rate = described_class.effective_taker_rate(symbol: dated, contract_notional_usd: 100.0)

      expect(rate).to be_within(1e-9).of(0.0085)
    end

    it "keeps the venue rate when the floor does not bind" do
      # On oil's real ~$930 contract the two are nearly equal by design.
      rate = described_class.effective_taker_rate(symbol: dated, contract_notional_usd: 10_000.0)

      expect(rate).to be_within(1e-9).of(described_class.dated_taker_rate)
    end

    it "prices a perp at the perp rate, not the dated one" do
      rate = described_class.effective_taker_rate(symbol: perp, contract_notional_usd: 10_000.0)

      expect(rate).to be_within(1e-9).of(described_class.taker_fee_rate)
      expect(rate).to be < described_class.dated_taker_rate
    end

    it "falls back to the bare venue rate when notional is unknown" do
      expect(described_class.effective_taker_rate(symbol: dated, contract_notional_usd: nil))
        .to be_within(1e-9).of(described_class.dated_taker_rate)
      expect(described_class.effective_taker_rate(symbol: dated, contract_notional_usd: 0))
        .to be_within(1e-9).of(described_class.dated_taker_rate)
    end
  end

  describe ".round_trip_cost_for" do
    it "charges a dated contract its own floor rather than the perp minimum" do
      cost = described_class.round_trip_cost_for(symbol: dated, entry_price: 100.0,
        exit_price: 100.0, quantity: 1.0, contracts: 1.0)

      # Both sides floored at $0.85, not the $0.15 perp minimum.
      expect(cost).to be_within(1e-9).of(1.70)
    end

    it "charges a perp the perp floor" do
      cost = described_class.round_trip_cost_for(symbol: perp, entry_price: 100.0,
        exit_price: 100.0, quantity: 1.0, contracts: 1.0)

      expect(cost).to be_within(1e-9).of(0.30)
    end

    it "uses the proportional fee once notional clears the floor" do
      cost = described_class.round_trip_cost_for(symbol: perp, entry_price: 100_000.0,
        exit_price: 100_000.0, quantity: 1.0, contracts: 1.0)

      expect(cost).to be_within(1e-6).of(2 * 100_000.0 * described_class.taker_fee_rate)
    end
  end

  describe ".round_trip_cost" do
    it "still defaults to the perp minimum when no floor is given" do
      cost = described_class.round_trip_cost(entry_price: 100.0, exit_price: 100.0,
        quantity: 1.0, fee_rate: 0.0001, contracts: 1.0)

      expect(cost).to be_within(1e-9).of(2 * described_class.min_fee_per_contract)
    end
  end
end
