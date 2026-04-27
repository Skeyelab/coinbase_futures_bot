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
  end
end
