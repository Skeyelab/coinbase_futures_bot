# frozen_string_literal: true

require "rails_helper"

RSpec.describe PositionReconcileService do
  let(:client) { instance_double(Coinbase::Client) }
  let(:service) { described_class.new(coinbase_client: client) }

  before do
    allow(client).to receive(:test_auth).and_return({advanced_trade: {ok: true, message: nil}})
  end

  describe "#reconcile!" do
    it "raises when Advanced Trade auth fails" do
      allow(client).to receive(:test_auth).and_return({advanced_trade: {ok: false, message: "bad key"}})
      expect { service.reconcile! }.to raise_error(/authentication failed/i)
    end

    it "closes local OPEN rows that are absent from the exchange snapshot" do
      pos = create(:position, product_id: "BIT-29AUG25-CDE", side: "LONG", status: "OPEN")
      allow(client).to receive(:futures_positions).and_return([])

      result = service.reconcile!

      expect(result[:closed_count]).to eq(1)
      expect(result[:closed_ids]).to eq([pos.id])
      expect(pos.reload.status).to eq("CLOSED")
      expect(pos.close_time).to be_present
    end

    it "does not close when a matching open contract exists on the exchange" do
      pos = create(:position, product_id: "BIT-29AUG25-CDE", side: "LONG", status: "OPEN")
      allow(client).to receive(:futures_positions).and_return([
        {
          "product_id" => "BIT-29AUG25-CDE",
          "number_of_contracts" => "1",
          "side" => "long",
          "avg_entry_price" => "50000"
        }
      ])

      result = service.reconcile!

      expect(result[:closed_count]).to eq(0)
      expect(pos.reload.status).to eq("OPEN")
    end

    it "skips zero-size exchange rows" do
      pos = create(:position, product_id: "BIT-29AUG25-CDE", side: "LONG", status: "OPEN")
      allow(client).to receive(:futures_positions).and_return([
        {"product_id" => "BIT-29AUG25-CDE", "number_of_contracts" => "0", "side" => "long"}
      ])

      result = service.reconcile!

      expect(result[:closed_count]).to eq(1)
      expect(pos.reload.status).to eq("CLOSED")
    end

    it "reuses a provided exchange snapshot without refetching" do
      pos = create(:position, product_id: "BIT-29AUG25-CDE", side: "LONG", status: "OPEN")
      allow(client).to receive(:futures_positions)

      result = service.reconcile!(exchange_rows: [])

      expect(client).not_to have_received(:futures_positions)
      expect(result[:closed_count]).to eq(1)
      expect(pos.reload.status).to eq("CLOSED")
    end

    it "uses contract-sized pnl when a recent market price exists" do
      pos = create(:position,
        product_id: "NOL-19JUN26-CDE",
        side: "SHORT",
        entry_price: 93.62,
        size: 1,
        status: "OPEN",
        pnl: 0.0)
      allow(Trading::ContractSizeResolver).to receive(:for_product).with("NOL-19JUN26-CDE").and_return(10)
      allow(RecentMarketPrice).to receive(:for_product).with("NOL-19JUN26-CDE").and_return(93.41)

      service.reconcile!(exchange_rows: [])

      expect(pos.reload.pnl).to eq(2.1)
    end

    it "falls back to last synced exchange pnl when no market price is available" do
      pos = create(:position,
        product_id: "NOL-19JUN26-CDE",
        side: "SHORT",
        entry_price: 93.62,
        size: 1,
        status: "OPEN",
        pnl: 3.6)
      allow(RecentMarketPrice).to receive(:for_product).with("NOL-19JUN26-CDE").and_return(nil)

      service.reconcile!(exchange_rows: [])

      expect(pos.reload.pnl).to eq(3.6)
    end
  end
end
