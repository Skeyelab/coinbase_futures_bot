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

  # Issue #462: the seeded dated fee was measured from OIL fills and then applied
  # to every dated contract — right for oil, a guess for a BTC nano on a
  # different schedule, and #459 carried that guess into the live gates.
  describe "measured fees override the seeded constant" do
    def measure!(product, per_contract, samples: 25)
      ProductFee.create!(product_id: product, liquidity: "TAKER",
        commission_per_contract: per_contract, sample_size: samples, measured_at: Time.current)
    end

    it "prefers a product's own measured commission over oil's" do
      measure!("BIT-29AUG25-CDE", 0.11)

      fee = described_class.fee_for("BIT-29AUG25-CDE")[:per_contract_fee]

      expect(fee).to eq(0.11)
      expect(fee).not_to eq(described_class.dated_fee_per_contract)
    end

    # Commission per contract needs no contract multiplier and is exact; the
    # effective bps depends on a resolver FeeTruth documents as unreliable for
    # some dated contracts. Measure the exact number, leave the approximate one.
    it "overrides only the exact number, leaving the rate seeded" do
      measure!(dated, 1.25)

      fees = described_class.fee_for(dated)

      expect(fees[:per_contract_fee]).to eq(1.25)
      expect(fees[:taker_rate]).to eq(described_class.dated_taker_rate)
    end

    it "falls back to the seeded constant when nothing has been measured" do
      expect(described_class.fee_for(dated)[:per_contract_fee])
        .to eq(described_class.dated_fee_per_contract)
    end

    it "reaches what the live gates actually charge" do
      measure!(dated, 2.00)

      cost = described_class.round_trip_cost_for(symbol: dated, entry_price: 100.0,
        exit_price: 100.0, quantity: 1.0, contracts: 1.0)

      expect(cost).to be_within(1e-9).of(4.00)
    end
  end
end
