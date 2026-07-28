# frozen_string_literal: true

require "rails_helper"

# ADR 0006 decision 1: ingestion and enablement are separate decisions.
#
# `upsert_products` wrote `enabled: true` on every run for every matching
# product. Two consequences:
#
#   - Adding one prefix to Contract::PREFIX_TO_BASE_CURRENCY produced an
#     enabled contract with no decision recorded anywhere.
#   - An operator's explicit disable was silently REVERTED on the next
#     ingestion cycle. The pipeline out-voted the human, every time, with no
#     log line saying so.
#
# Ingestion now grants data collection for products it has never seen and is
# not authoritative over rows that already exist. What ingestion can never
# grant is tradeability: that is Trading::SymbolSuspension, and it fails closed.
RSpec.describe MarketData::CoinbaseRest, "ingestion vs enablement" do
  subject(:service) { described_class.new }

  let(:products) do
    [{"product_id" => "BIP-20DEC30-CDE", "trading_disabled" => false,
      "base_min_size" => "1", "quote_increment" => "0.01", "base_increment" => "1"}]
  end

  before do
    allow(service).to receive(:list_products).and_return(products)
    allow(Rails.logger).to receive(:info)
  end

  it "collects data for a product it has never seen before" do
    service.upsert_products

    expect(Contract.find_by(product_id: "BIP-20DEC30-CDE").enabled).to be true
  end

  it "does not revert an operator's explicit disable on the next ingestion run" do
    Contract.create!(product_id: "BIP-20DEC30-CDE", base_currency: "BTC", quote_currency: "USD",
      expiration_date: Date.new(2030, 12, 20), contract_type: "CDE", enabled: false)

    service.upsert_products

    expect(Contract.find_by(product_id: "BIP-20DEC30-CDE").enabled).to be false
  end

  it "still refreshes everything else about a disabled row" do
    Contract.create!(product_id: "BIP-20DEC30-CDE", base_currency: "BTC", quote_currency: "USD",
      expiration_date: Date.new(2030, 12, 20), contract_type: "CDE", enabled: false,
      price_increment: 99.0)

    service.upsert_products

    row = Contract.find_by(product_id: "BIP-20DEC30-CDE")
    expect(row.price_increment.to_f).to eq(0.01)
    expect(row.enabled).to be false
  end

  # The point of the separation: a newly-ingested product is collecting candles
  # and is NOT tradeable, which is what contract.rb has claimed since PAU landed.
  it "leaves a freshly-ingested product blocked from trading", universe_scope: true do
    service.upsert_products

    expect(Trading::SymbolSuspension.suspended?("BIP-20DEC30-CDE")).to be true
  end
end
