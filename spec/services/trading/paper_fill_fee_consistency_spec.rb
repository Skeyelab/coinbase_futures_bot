# frozen_string_literal: true

require "rails_helper"

# Issue #524. Paper positions 9/10 on exo-mini carried fees from two different
# models — one position charged the perp floor ($0.15) on entry and dated
# pricing ($0.889743) on exit. Mechanism: before #507, simulate_order inlined
# the PERP schedule for every product AND priced notional as price*size
# (dropping contract_size, the #234 shape), so the proportional leg came out
# tiny and the $0.15 floor won. #507 moved simulate_order onto
# CostModel.fee_for + NotionalCap.notional_for. Both the entry and the exit
# funnel through submit_order -> simulate_order in dry-run, so one pricing
# site serves both sides. These pin that.
RSpec.describe Trading::CoinbasePositions, "paper fill fee model consistency (#524)" do
  let(:service) { described_class.new }
  let(:dated_product) { "NOL-19AUG26-CDE" }
  let(:price) { 98.86 }
  let(:contract_size) { 10 }

  before do
    allow(DryRun).to receive(:active?).and_return(true)
    allow(service).to receive(:get_current_market_price).and_return(price)
    allow(Trading::ContractSizeResolver).to receive(:for_product).and_return(contract_size)
    allow(ProductFee).to receive(:measured_per_contract).and_return(nil)
  end

  def entry_fee(product)
    service.submit_order({}, product_id: product, side: :buy, size: 1, intent: :entry)["fee"]
  end

  def exit_fee(product)
    service.close_position(product_id: product, size: "1")["fee"]
  end

  it "prices a dated-CDE paper fill under the dated model on BOTH sides" do
    notional = contract_size * price * 1
    expected = [notional * CostModel.dated_taker_rate,
      1 * CostModel.dated_fee_per_contract].max.round(6)

    expect(entry_fee(dated_product)).to eq(expected)
    expect(exit_fee(dated_product)).to eq(expected)
  end

  it "does not price a dated fill at the perp floor" do
    expect(entry_fee(dated_product)).not_to eq(CostModel.min_fee_per_contract)
  end

  it "prices a perp paper fill under the perp model on both sides" do
    perp_product = "BIP-20DEC30-CDE"
    FundingRate.create!(product_id: perp_product, funding_rate: 0.0001,
      funding_time: Time.current, observed_at: Time.current,
      funding_interval_seconds: 3600)
    allow(service).to receive(:get_current_market_price).and_return(65_900.0)
    allow(Trading::ContractSizeResolver).to receive(:for_product).and_return(0.01)

    notional = 0.01 * 65_900.0 * 1
    expected = [notional * CostModel.taker_fee_rate,
      1 * CostModel.min_fee_per_contract].max.round(6)

    expect(entry_fee(perp_product)).to eq(expected)
    expect(exit_fee(perp_product)).to eq(expected)
  end
end
