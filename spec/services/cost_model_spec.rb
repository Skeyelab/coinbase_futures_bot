# frozen_string_literal: true

require "rails_helper"

RSpec.describe CostModel do
  describe ".taker_fee_rate" do
    it "defaults to 15 bps" do
      ClimateControl.modify(BACKTEST_TAKER_FEE_RATE: nil, TAKER_FEE_RATE: nil) do
        expect(described_class.taker_fee_rate).to eq(0.0015)
      end
    end

    it "honors BACKTEST_TAKER_FEE_RATE" do
      ClimateControl.modify(BACKTEST_TAKER_FEE_RATE: "0.002") do
        expect(described_class.taker_fee_rate).to eq(0.002)
      end
    end
  end

  describe ".round_trip_cost" do
    it "sums per-side fees plus slippage on entry and exit notional" do
      cost = described_class.round_trip_cost(
        entry_price: 100.0, exit_price: 110.0, quantity: 2.0,
        fee_rate: 0.001, slippage_rate: 0.0005
      )
      expect(cost).to be_within(1e-9).of((100.0 + 110.0) * 2.0 * 0.0015)
    end
  end
end
