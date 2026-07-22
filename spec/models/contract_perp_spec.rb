# frozen_string_literal: true

require "rails_helper"

# Perp ingestion (issue #411, ADR 0002). CDE perps share the dated product-ID
# shape — PREFIX-DDMMMYY-CDE — so nothing about the format distinguishes them.
# What distinguishes them is the prefix map, and every failure mode here is
# SILENT: an unmapped perp resolves its underlying to the raw prefix, gets no
# spot reference feed, and looks like a working contract row.
RSpec.describe Contract, type: :model do
  describe "PREFIX_TO_BASE_CURRENCY" do
    it "maps the ADR 0002 perps to the assets they actually track" do
      expect(described_class::PREFIX_TO_BASE_CURRENCY["BIP"]).to eq("BTC")
      expect(described_class::PREFIX_TO_BASE_CURRENCY["XPP"]).to eq("XRP")
    end

    it "keeps the dated prefixes mapped so the venue migration is additive" do
      expect(described_class::PREFIX_TO_BASE_CURRENCY).to include(
        "BIT" => "BTC", "ET" => "ETH", "NOL" => "OIL"
      )
    end
  end

  describe ".parse_contract_info on perp product ids" do
    # Real product ids read from list_products on 2026-07-22.
    it "resolves BIP to BTC rather than to the raw prefix" do
      info = described_class.parse_contract_info("BIP-20DEC30-CDE")

      expect(info[:base_currency]).to eq("BTC")
      expect(info[:contract_type]).to eq("CDE")
      expect(info[:expiration_date]).to eq(Date.new(2030, 12, 20))
    end

    it "resolves XPP to XRP" do
      expect(described_class.parse_contract_info("XPP-20DEC30-CDE")[:base_currency]).to eq("XRP")
    end

    it "falls back to the prefix for unmapped products instead of raising" do
      # SLP (SOL perp) is deliberately not ingested yet. It must degrade
      # predictably rather than blow up, but note the fallback is lossy —
      # that lossiness is why the prefix map gates ingestion upstream.
      expect(described_class.parse_contract_info("SLP-20DEC30-CDE")[:base_currency]).to eq("SLP")
    end
  end

  describe "perps and the expiry sweep (issue #368)" do
    # FetchCandlesJob disables any enabled contract whose expiration_date has
    # passed. Perps carry a 2030 dummy expiry, so they survive — but if Coinbase
    # ever reissues them on a nearer date, collection would stop silently.
    it "parses a far-future expiry that keeps perps clear of the sweep" do
      expiry = described_class.parse_expiry_date("BIP-20DEC30-CDE")

      expect(expiry).to eq(Date.new(2030, 12, 20))
      expect(expiry).to be > Date.current + 1.year
    end

    it "treats a perp contract as tradeable and not expired" do
      contract = described_class.create!(
        product_id: "BIP-20DEC30-CDE", base_currency: "BTC", quote_currency: "USD",
        expiration_date: Date.new(2030, 12, 20), enabled: true
      )

      expect(described_class.not_expired).to include(contract)
      expect(described_class.tradeable).to include(contract)
    end
  end

  describe "#underlying_asset" do
    it "returns the tracked asset for a perp, which is what drives the spot feed" do
      contract = described_class.new(product_id: "BIP-20DEC30-CDE", base_currency: "BIP")

      # base_currency on the row is deliberately wrong here to prove the parse
      # takes precedence — a mis-stored row must not cost us the spot feed.
      expect(contract.underlying_asset).to eq("BTC")
    end
  end
end
