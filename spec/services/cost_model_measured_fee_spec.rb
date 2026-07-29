# frozen_string_literal: true

require "rails_helper"

# Issue #583. The first real BIP fills (#486, 2026-07-29) decompose exactly:
#
#   $0.65496 = 643.70 × 0.0008 + $0.14000
#   $0.65484 = 643.55 × 0.0008 + $0.14000
#
# A perp is charged a proportional venue rate PLUS a flat per-contract amount.
# fee_for merged a measured commission in as `per_contract_fee` while leaving
# `taker_rate` seeded, which adds the proportional part twice:
#
#   643.70 × 0.0003 + 0.6549 = $0.848   against a real $0.65496
#
# 29% over, on every backtest, cost gate and simulated fill, the moment
# ProductFee reaches min_sample_size. It was sitting at 2 of 3 when this was
# found.
RSpec.describe CostModel, "a measured commission is not double-counted (issue #583)" do
  let(:perp) { "BIP-20DEC30-CDE" }
  let(:dated) { "NOL-19AUG26-CDE" }

  # The real numbers from the #486 round trip.
  let(:notional) { 643.70 }
  let(:real_commission) { 0.65496 }
  let(:measured_rate) { real_commission / notional }

  # perp?(symbol) is true iff snapshotted FundingRate rows exist (#457).
  before do
    FundingRate.create!(product_id: perp, funding_time: 1.hour.ago, funding_rate: 0.000014,
      funding_interval_seconds: 3600, observed_at: 1.hour.ago)
  end

  def measure!(product, commission:, rate:, liquidity: "TAKER")
    ProductFee.create!(product_id: product, liquidity: liquidity,
      commission_per_contract: commission, effective_rate: rate,
      sample_size: ProductFee.min_sample_size, measured_at: Time.current)
  end

  # What anything pricing a trade actually does with the returned hash.
  def priced(fees, contract_notional)
    contract_notional * fees[:taker_rate].to_f + fees[:per_contract_fee].to_f
  end

  # product_fees.effective_rate is decimal(12, 8), so a rate round-trips through
  # the column with a 1e-8 quantum — about $6e-6 of resolution at a $644
  # notional. Asserting tighter than the schema can represent tests the column,
  # not the arithmetic. The defect this file exists for was 29% ($0.19).
  let(:rate_storage_tolerance) { 1e-5 }

  # The tracer. A measurement OF a commission must not price ABOVE that
  # commission at the notional it was measured at.
  it "reproduces the measured commission rather than exceeding it" do
    measure!(perp, commission: real_commission, rate: measured_rate)

    expect(priced(described_class.fee_for(perp), notional)).to be_within(rate_storage_tolerance).of(real_commission)
  end

  # The measurement is a rate on a perp, so it has to travel with price. Pinning
  # it as a flat dollar amount would be exact at $643 and wrong everywhere else,
  # and BTC does not hold still.
  it "scales the measured perp commission with notional" do
    measure!(perp, commission: real_commission, rate: measured_rate)

    doubled = priced(described_class.fee_for(perp), notional * 2)

    expect(doubled).to be_within(rate_storage_tolerance * 2).of(real_commission * 2)
  end

  # The dated path is NOT what this issue is about and must not regress. On NOL
  # the fee genuinely is a flat per-contract charge (~$0.85 measured from oil
  # fills, #462), and merging it as per_contract_fee is correct there.
  it "still treats a measured dated commission as a flat per-contract charge" do
    measure!(dated, commission: 0.85, rate: nil)

    fees = described_class.fee_for(dated)

    expect(fees[:per_contract_fee]).to be_within(1e-9).of(0.85)
    expect(fees[:taker_rate]).to be_within(1e-9).of(described_class.dated_taker_rate)
  end

  # Below min_sample_size nothing is trustworthy yet, so the seeded constants
  # stand. This is the state the bug was found in — 2 fills of a required 3.
  it "ignores a measurement too thin to trust" do
    ProductFee.create!(product_id: perp, liquidity: "TAKER",
      commission_per_contract: real_commission, effective_rate: measured_rate,
      sample_size: ProductFee.min_sample_size - 1, measured_at: Time.current)

    fees = described_class.fee_for(perp)

    expect(fees[:taker_rate]).to be_within(1e-9).of(described_class.taker_fee_rate)
    expect(fees[:per_contract_fee]).to be_within(1e-9).of(described_class.min_fee_per_contract)
  end

  # A perp row with no usable rate cannot become a rate. Falling back to the
  # flat amount is still exact at the measured notional; falling back to the
  # SEEDED rate plus the measurement is the bug.
  it "does not fall back to seeded-rate-plus-measurement when the rate is missing" do
    measure!(perp, commission: real_commission, rate: nil)

    expect(priced(described_class.fee_for(perp), notional)).to be <= real_commission + 1e-6
  end

  # measured_rate is public and reachable without measured_per_contract, so its
  # own sample floor has to hold on its own. Testing it only through fee_for
  # tests the guard upstream of it and leaves this one free to rot.
  describe ProductFee, ".measured_rate" do
    let(:perp) { "BIP-20DEC30-CDE" }

    it "withholds a rate until enough fills stand behind it" do
      row = described_class.create!(product_id: perp, liquidity: "TAKER",
        commission_per_contract: 0.65496, effective_rate: 0.00101749,
        sample_size: described_class.min_sample_size - 1, measured_at: Time.current)

      expect(described_class.measured_rate(perp)).to be_nil

      row.update!(sample_size: described_class.min_sample_size)

      expect(described_class.measured_rate(perp)).to be_within(1e-9).of(0.00101749)
    end

    # A zero rate is not a measurement of "free" — it is a row that could not be
    # expressed as a rate. Returning it would price the product at nothing.
    it "treats a zero rate as absent rather than as free trading" do
      described_class.create!(product_id: perp, liquidity: "TAKER",
        commission_per_contract: 0.65496, effective_rate: 0.0,
        sample_size: described_class.min_sample_size, measured_at: Time.current)

      expect(described_class.measured_rate(perp)).to be_nil
    end
  end
end
