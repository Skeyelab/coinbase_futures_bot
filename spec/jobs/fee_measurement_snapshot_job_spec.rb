# frozen_string_literal: true

require "rails_helper"

# Issue #462: replaces the single seeded dated constant (measured by hand from
# oil fills, then applied to every dated contract) with per-product observation.
RSpec.describe FeeMeasurementSnapshotJob do
  let(:now) { Time.utc(2026, 7, 27, 12, 0, 0) }

  def report(measurements, status: "ok", fills: 50)
    fee_truth = class_double(Trading::FeeTruth)
    allow(fee_truth).to receive(:call).and_return(
      {status: status, fills_examined: fills, by_product_liquidity: measurements}
    )
    fee_truth
  end

  it "stores a measured commission per product and liquidity" do
    fee_truth = report([
      {product: "NOL-19AUG26-CDE", liquidity: "TAKER", count: 12,
       avg_commission_per_contract: 0.85, avg_effective_rate: 0.0009},
      {product: "BIT-29AUG25-CDE", liquidity: "TAKER", count: 8,
       avg_commission_per_contract: 0.11, avg_effective_rate: 0.0004}
    ])

    described_class.new.perform(now: now, fee_truth: fee_truth)

    expect(ProductFee.count).to eq(2)
    expect(ProductFee.measured_per_contract("NOL-19AUG26-CDE")).to eq(0.85)
    expect(ProductFee.measured_per_contract("BIT-29AUG25-CDE")).to eq(0.11)
  end

  # The whole point: a BTC nano stops inheriting oil's per-contract fee.
  it "makes CostModel price each dated product on its own measurement" do
    fee_truth = report([
      {product: "BIT-29AUG25-CDE", liquidity: "TAKER", count: 8,
       avg_commission_per_contract: 0.11, avg_effective_rate: 0.0004}
    ])

    expect { described_class.new.perform(now: now, fee_truth: fee_truth) }
      .to change { CostModel.fee_for("BIT-29AUG25-CDE")[:per_contract_fee] }
      .from(CostModel.dated_fee_per_contract).to(0.11)
  end

  it "keeps taker and maker measurements apart" do
    fee_truth = report([
      {product: "NOL-19AUG26-CDE", liquidity: "TAKER", count: 12,
       avg_commission_per_contract: 0.85, avg_effective_rate: 0.0009},
      {product: "NOL-19AUG26-CDE", liquidity: "MAKER", count: 5,
       avg_commission_per_contract: 0.20, avg_effective_rate: 0.0002}
    ])

    described_class.new.perform(now: now, fee_truth: fee_truth)

    expect(ProductFee.measured_per_contract("NOL-19AUG26-CDE", liquidity: "TAKER")).to eq(0.85)
    expect(ProductFee.measured_per_contract("NOL-19AUG26-CDE", liquidity: "MAKER")).to eq(0.20)
  end

  it "refreshes an existing measurement instead of accumulating rows" do
    described_class.new.perform(now: now, fee_truth: report([
      {product: "NOL-19AUG26-CDE", liquidity: "TAKER", count: 5,
       avg_commission_per_contract: 0.85, avg_effective_rate: 0.0009}
    ]))
    described_class.new.perform(now: now + 1.day, fee_truth: report([
      {product: "NOL-19AUG26-CDE", liquidity: "TAKER", count: 40,
       avg_commission_per_contract: 0.92, avg_effective_rate: 0.001}
    ]))

    expect(ProductFee.count).to eq(1)
    fee = ProductFee.for_product("NOL-19AUG26-CDE").taker.first
    expect(fee.commission_per_contract.to_f).to eq(0.92)
    expect(fee.sample_size).to eq(40)
    expect(fee.measured_at).to eq(now + 1.day)
  end

  # Leaving the seeded constants alone beats writing a measurement of nothing.
  it "writes nothing when there are no credentials or no fills" do
    expect { described_class.new.perform(now: now, fee_truth: report([], status: "not_authenticated")) }
      .not_to change(ProductFee, :count)

    expect { described_class.new.perform(now: now, fee_truth: report([])) }
      .not_to change(ProductFee, :count)
  end

  it "skips a product whose measured commission is not positive" do
    fee_truth = report([
      {product: "NOL-19AUG26-CDE", liquidity: "TAKER", count: 3,
       avg_commission_per_contract: 0.0, avg_effective_rate: 0.0}
    ])

    expect { described_class.new.perform(now: now, fee_truth: fee_truth) }
      .not_to change(ProductFee, :count)
  end
end
