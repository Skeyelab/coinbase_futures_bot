# frozen_string_literal: true

require "rails_helper"
require "tui"

RSpec.describe Tui::ExchangePnlRefresher do
  describe ".refresh!" do
    let(:positions_service) { instance_double(Trading::CoinbasePositions) }
    let!(:position) do
      create(:position,
        product_id: "NOL-19JUN26-CDE",
        side: "SHORT",
        entry_price: 93.62,
        size: 1,
        pnl: 0.0)
    end

    before do
      Rails.cache.delete("contract_size:NOL-19JUN26-CDE")
      allow(positions_service).to receive(:list_open_positions).and_return([
        {
          "product_id" => "NOL-19JUN26-CDE",
          "side" => "SHORT",
          "number_of_contracts" => "1",
          "avg_entry_price" => "93.62",
          "current_price" => "93.46",
          "unrealized_pnl" => "2.5"
        }
      ])
      allow(Trading::ContractSizeResolver).to receive(:for_product).with("NOL-19JUN26-CDE").and_return(10)
    end

    it "updates open positions with computed unrealized pnl" do
      described_class.refresh!(positions_service: positions_service)

      expect(position.reload.pnl).to eq(1.6)
    end
  end
end
