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

    # Issue #411 / ADR 0002. A perp's spot feed comes from underlying_asset,
    # which is resolved through Contract::PREFIX_TO_BASE_CURRENCY — so an
    # unmapped prefix yields e.g. "BIP-USD", falls out of the allowlist, and the
    # symbol runs with no spot reference. Silently.
    it "resolves the BTC perp to the BTC spot feed" do
      create(:contract, product_id: "BIP-20DEC30-CDE", base_currency: "BTC", enabled: true)

      expect(described_class.spot_product_ids).to include("BTC-USD")
    end

    it "resolves the XRP perp to the XRP spot feed" do
      create(:contract, product_id: "XPP-20DEC30-CDE", base_currency: "XRP", enabled: true)

      expect(described_class.spot_product_ids).to include("XRP-USD")
    end

    it "does not invent a spot feed for an underlying that has no spot market" do
      # OIL trades only as a future. Deriving the allowlist from the prefix map
      # would subscribe to a nonexistent OIL-USD, which is why the two lists
      # are kept separate.
      create(:contract, product_id: "NOL-19JUN26-CDE", base_currency: "OIL", enabled: true)

      expect(described_class.spot_product_ids).not_to include("OIL-USD")
    end
  end
end
