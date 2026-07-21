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

    it "applies the flat per-contract floor when contracts are given (issue #372)" do
      # Coinbase US futures: ~0.02%/contract with a $0.15/contract MINIMUM.
      # 2 contracts x $80 notional/side: proportional = $0.24/side; floor =
      # $0.30/side -> floor binds. Round trip = 2 x $0.30.
      cost = described_class.round_trip_cost(
        entry_price: 80.0, exit_price: 80.0, quantity: 2.0,
        fee_rate: 0.0015, contracts: 2
      )
      expect(cost).to be_within(1e-9).of(0.60)
    end

    it "keeps proportional fees when they exceed the floor" do
      # 2 contracts x $600 notional/side: proportional $1.80/side > $0.30 floor
      cost = described_class.round_trip_cost(
        entry_price: 600.0, exit_price: 600.0, quantity: 2.0,
        fee_rate: 0.0015, contracts: 2
      )
      expect(cost).to be_within(1e-9).of(3.60)
    end
  end

  describe ".min_fee_per_contract" do
    it "defaults to $0.15 and honors the env override" do
      ClimateControl.modify(TAKER_MIN_FEE_PER_CONTRACT: nil) do
        expect(described_class.min_fee_per_contract).to eq(0.15)
      end
      ClimateControl.modify(TAKER_MIN_FEE_PER_CONTRACT: "0.2") do
        expect(described_class.min_fee_per_contract).to eq(0.2)
      end
    end
  end
end
