# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trading::FuturesUnrealizedPnl do
  describe ".calculate" do
    it "computes dollar pnl for a short NOL position using contract size" do
      pnl = described_class.calculate(
        side: "SHORT",
        entry_price: 93.62,
        current_price: 93.46,
        contracts: 1,
        contract_size: 10
      )

      expect(pnl).to eq(1.6)
    end

    it "computes dollar pnl for a long position" do
      pnl = described_class.calculate(
        side: "LONG",
        entry_price: 50_000,
        current_price: 51_000,
        contracts: 2,
        contract_size: 1
      )

      expect(pnl).to eq(2_000.0)
    end

    it "returns nil when required inputs are missing" do
      expect(described_class.calculate(side: "LONG", entry_price: nil, current_price: 100, contracts: 1)).to be_nil
    end

    it "returns nil for unknown sides" do
      expect(described_class.calculate(side: "UNKNOWN", entry_price: 100, current_price: 101, contracts: 1)).to be_nil
    end
  end

  describe ".from_exchange_position" do
    let(:exchange_position) do
      {
        "product_id" => "NOL-19JUN26-CDE",
        "side" => "SHORT",
        "number_of_contracts" => "1",
        "avg_entry_price" => "93.62",
        "current_price" => "93.46",
        "unrealized_pnl" => "2.5"
      }
    end
    let(:contract_size_resolver) { class_double(Trading::ContractSizeResolver) }

    before do
      allow(contract_size_resolver).to receive(:for_product).with("NOL-19JUN26-CDE").and_return(10)
    end

    it "ignores the exchange unrealized_pnl field and uses mark math" do
      pnl = described_class.from_exchange_position(
        exchange_position,
        contract_size_resolver: contract_size_resolver
      )

      expect(pnl).to eq(1.6)
    end
  end
end
