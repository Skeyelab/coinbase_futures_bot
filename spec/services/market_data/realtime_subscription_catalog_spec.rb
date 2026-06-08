# frozen_string_literal: true

require "rails_helper"

RSpec.describe MarketData::RealtimeSubscriptionCatalog do
  describe ".futures_contract?" do
    it "returns true for CDE futures product ids" do
      expect(described_class.futures_contract?("NOL-19JUN26-CDE")).to be(true)
      expect(described_class.futures_contract?("BIT-27JUN26-CDE")).to be(true)
    end

    it "returns false for spot product ids" do
      expect(described_class.futures_contract?("BTC-USD")).to be(false)
    end
  end

  describe ".futures_product_ids" do
    it "includes enabled contract product ids" do
      create(:contract, product_id: "NOL-19JUN26-CDE", base_currency: "NOL", enabled: true)
      create(:contract, asset: "BTC", enabled: false)

      expect(described_class.futures_product_ids).to include("NOL-19JUN26-CDE")
    end

    it "includes open position product ids even when contract row is missing" do
      create(:position, product_id: "NOL-19JUN26-CDE", status: "OPEN")

      expect(described_class.futures_product_ids).to include("NOL-19JUN26-CDE")
    end
  end

  describe ".spot_product_ids" do
    it "returns supported spot ids derived from enabled contracts" do
      create(:contract, asset: "BTC", enabled: true)
      create(:contract, product_id: "NOL-19JUN26-CDE", base_currency: "NOL", enabled: true)

      expect(described_class.spot_product_ids).to eq(["BTC-USD"])
    end
  end
end
