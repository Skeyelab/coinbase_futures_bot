# frozen_string_literal: true

require "rails_helper"

RSpec.describe PositionImportService do
  let(:client) { instance_double(Coinbase::Client) }
  let(:service) { described_class.new }

  before do
    allow(Coinbase::Client).to receive(:new).and_return(client)
    allow(client).to receive(:test_auth).and_return({advanced_trade: {ok: true, message: nil}})
  end

  describe "#import_positions_from_coinbase" do
    it "auto-reconciles local OPEN rows missing from the exchange snapshot" do
      ghost = create(:position, product_id: "NOL-19JUN26-CDE", side: "SHORT", status: "OPEN", pnl: 4.2)
      allow(client).to receive(:futures_positions).and_return([])
      allow(RecentMarketPrice).to receive(:for_product).and_return(nil)

      result = service.import_positions_from_coinbase

      expect(ghost.reload.status).to eq("CLOSED")
      expect(result[:reconciled]).to eq(1)
      expect(result[:reconciled_ids]).to eq([ghost.id])
    end

    it "skips auto-reconcile when FUTURESBOT_SKIP_AUTO_RECONCILE is set" do
      ghost = create(:position, product_id: "NOL-19JUN26-CDE", side: "SHORT", status: "OPEN")
      allow(client).to receive(:futures_positions).and_return([])

      result = nil
      ClimateControl.modify(FUTURESBOT_SKIP_AUTO_RECONCILE: "1") do
        result = service.import_positions_from_coinbase
      end

      expect(ghost.reload.status).to eq("OPEN")
      expect(result[:reconciled]).to eq(0)
    end
  end
end
