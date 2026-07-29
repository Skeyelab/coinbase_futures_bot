# frozen_string_literal: true

require "rails_helper"

# Issue #390. The positions service kept its own dated-only product map, so a
# BIP or NOL position was an asset it could not name — invisible to
# positions_by_asset and therefore to rollover. Every resolution site has to
# agree on the same prefix map, or a partial migration routes one path to the
# perp and leaves another on the dated contract.
RSpec.describe Trading::CoinbasePositions, "venue routing" do
  subject(:service) { described_class.new(logger: logger) }

  let(:logger) { instance_double(Logger, info: nil, warn: nil, error: nil, debug: nil) }

  before do
    allow_any_instance_of(described_class).to receive(:build_jwt_token).and_return("test-jwt-token")
    allow(Coinbase::CredentialResolver).to receive(:call).and_return({
      api_key: "organizations/test-org/apiKeys/test-key",
      private_key: "test-private-key"
    })
  end

  describe "#extract_asset_from_product_id" do
    it "names the asset behind the BIP perp" do
      expect(service.send(:extract_asset_from_product_id, "BIP-20DEC30-CDE")).to eq("BTC")
    end

    it "names the asset behind the dated oil contract" do
      expect(service.send(:extract_asset_from_product_id, "NOL-19JUN26-CDE")).to eq("OIL")
    end

    it "still names the dated crypto contracts" do
      expect(service.send(:extract_asset_from_product_id, "BIT-29AUG25-CDE")).to eq("BTC")
      expect(service.send(:extract_asset_from_product_id, "ET-29AUG25-CDE")).to eq("ETH")
    end

    it "returns nil for a product it cannot place" do
      expect(service.send(:extract_asset_from_product_id, "WAT-29AUG25-CDE")).to be_nil
    end
  end

  describe "#open_best_available_position" do
    let!(:btc_perp) do
      create(:contract, product_id: "BIP-20DEC30-CDE", base_currency: "BTC", enabled: true,
        expiration_date: Date.new(2030, 12, 20))
    end

    before do
      create(:contract, product_id: "BIT-28AUG26-CDE", base_currency: "BTC", enabled: true,
        expiration_date: 1.month.from_now.to_date)
      allow(service).to receive(:open_position).and_return({"success" => true})
    end

    it "opens BTC exposure on the perp rather than the dated month contract" do
      service.open_best_available_position(asset: "BTC", side: :buy, size: 1)

      expect(service).to have_received(:open_position)
        .with(hash_including(product_id: "BIP-20DEC30-CDE"))
    end

    # The legacy asset-keyed entry point resolves the same way. Two entry points
    # that disagree about which contract "BTC" means is the bug this issue is
    # about, so it is not enough that the new one is right.
    it "routes the legacy asset-keyed open to the same contract" do
      service.open_current_month_position("BTC", :buy, 1)

      expect(service).to have_received(:open_position)
        .with(hash_including(product_id: "BIP-20DEC30-CDE"))
    end
  end

  describe "rolling an expiring dated position" do
    before do
      create(:contract, product_id: "BIP-20DEC30-CDE", base_currency: "BTC", enabled: true,
        expiration_date: Date.new(2030, 12, 20))
      create(:contract, product_id: "BIT-31JUL26-CDE", base_currency: "BTC", enabled: true,
        expiration_date: 1.day.from_now.to_date)
      allow(service).to receive(:rollover_single_position)
    end

    # A roll is the moment an expiring dated position has to go somewhere. It
    # goes to the asset's venue, which for BTC is the perp — rolling into the
    # next dated month would re-enter the venue ADR 0002 migrated off.
    it "rolls an expiring BIT position onto the perp, not the next dated month" do
      positions = [{"product_id" => "BIT-31JUL26-CDE", "side" => "LONG", "number_of_contracts" => "1"}]

      service.send(:rollover_asset_positions, "BTC", positions)

      expect(service).to have_received(:rollover_single_position)
        .with(anything, "BIP-20DEC30-CDE", "BTC")
    end
  end
end
