# frozen_string_literal: true

require "rails_helper"

# Perp ingestion filter (issue #411, ADR 0002).
#
# Before this, upsert_products filtered on a literal /^(BIT|ET|NOL)-/ — so all
# 28 CDE perps were excluded, no Contract row was ever created for BIP, and
# FetchCandlesJob (which iterates Contract.enabled) collected zero perp candles.
# The gate clock for ADR 0002's no-evidence-inheritance rule could never start.
#
# The failure was entirely silent: no error, no log line, just a symbol that
# never accumulated history. These specs exist to keep it that way only for
# products we have deliberately chosen not to ingest.
RSpec.describe MarketData::CoinbaseRest do
  subject(:service) { described_class.new }

  # Real product ids and shapes read from list_products on 2026-07-22.
  let(:products) do
    [
      {"product_id" => "BIT-27JUN26-CDE", "trading_disabled" => false},   # dated BTC
      {"product_id" => "BIP-20DEC30-CDE", "trading_disabled" => false},   # BTC perp
      {"product_id" => "XPP-20DEC30-CDE", "trading_disabled" => false},   # XRP perp
      {"product_id" => "SLP-20DEC30-CDE", "trading_disabled" => false},   # SOL perp, not ingested
      {"product_id" => "ETP-20DEC30-CDE", "trading_disabled" => false},   # ETH perp, not ingested
      {"product_id" => "BTC-USD", "trading_disabled" => false},           # spot
      {"product_id" => "BIP-20DEC30-CDE-X", "trading_disabled" => true}   # disabled
    ]
  end

  before do
    allow(service).to receive(:list_products).and_return(products)
    allow(Contract).to receive(:upsert)
    allow(Rails.logger).to receive(:info)
  end

  def upserted_product_ids
    service.upsert_products
    ids = []
    expect(Contract).to have_received(:upsert) { |attrs, **_| ids << attrs[:product_id] }.at_least(:once)
    ids
  end

  it "ingests the ADR 0002 perps so candle collection can start" do
    expect(upserted_product_ids).to include("BIP-20DEC30-CDE", "XPP-20DEC30-CDE")
  end

  it "still ingests dated contracts — the venue migration is additive, not a swap" do
    expect(upserted_product_ids).to include("BIT-27JUN26-CDE")
  end

  it "does not ingest perps we have not chosen to collect" do
    # ADR 0002 admits perps one at a time; each re-earns enablement on its own
    # walk-forward. Ingesting all 28 would start 28 gate clocks nobody is watching.
    expect(upserted_product_ids).not_to include("SLP-20DEC30-CDE", "ETP-20DEC30-CDE")
  end

  it "does not mistake the ETP perp for the dated ET prefix" do
    # "ET" is a live prefix and "ETP-" starts with it. Only the trailing hyphen
    # keeps them apart, so this is a regression guard on the filter's shape.
    expect(upserted_product_ids).not_to include("ETP-20DEC30-CDE")
  end

  it "ignores spot products" do
    expect(upserted_product_ids).not_to include("BTC-USD")
  end

  it "skips trading-disabled products" do
    expect(upserted_product_ids).not_to include("BIP-20DEC30-CDE-X")
  end
end
