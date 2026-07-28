# frozen_string_literal: true

require "rails_helper"

# Why enabled futures contracts sit with NULL intraday_margin_rate_long, which
# leaves Trading::LiquidationBuffer UNARMED on them.
#
# Contract::PREFIX_TO_BASE_CURRENCY gates `ingestible_product_id?`, and
# upsert_products skips anything it rejects. That is right for CREATION — the
# map is the statement of which products we collect at all. It was also, by
# accident, gating REFRESH: a Contract row whose prefix is not in the map (a
# legacy row that predates the map, or one written by another path) was never
# revisited, so it could never receive the margin data that shipped later.
#
# On the live box that is GOL-*, SLR-*, SLP-* and ETP-* — four enabled futures
# rows for prefixes the map does not contain. The map decides what we start
# collecting; it must not decide whether a row we already have gets the number
# the liquidation rail depends on.
RSpec.describe MarketData::CoinbaseRest, "margin backfill for known contracts" do
  subject(:service) { described_class.new }

  let(:products) do
    [
      {"product_id" => "BIP-20DEC30-CDE", "trading_disabled" => false,
       "future_product_details" => {
         "intraday_margin_rate" => {"long_margin_rate" => "0.1000185", "short_margin_rate" => "0.1000008"}
       }},
      # Prefix absent from PREFIX_TO_BASE_CURRENCY — never ingested, but a row exists.
      {"product_id" => "GOL-29JUL26-CDE", "trading_disabled" => false,
       "future_product_details" => {
         "intraday_margin_rate" => {"long_margin_rate" => "0.05", "short_margin_rate" => "0.055"},
         "overnight_margin_rate" => {"long_margin_rate" => "0.09", "short_margin_rate" => "0.10"}
       }}
    ]
  end

  before do
    allow(service).to receive(:list_products).and_return(products)
    allow(Rails.logger).to receive(:info)
  end

  def existing_gold
    Contract.create!(product_id: "GOL-29JUL26-CDE", base_currency: "GOLD", quote_currency: "USD",
      expiration_date: Date.new(2026, 7, 29), contract_type: "CDE", enabled: true)
  end

  it "backfills margin on an enabled contract whose prefix is not in the ingestion map" do
    gold = existing_gold

    service.upsert_products

    expect(gold.reload.intraday_margin_rate_long.to_f).to be_within(1e-9).of(0.05)
    expect(gold.overnight_margin_rate_short.to_f).to be_within(1e-9).of(0.10)
  end

  it "does not create a contract for an unmapped prefix — the map still gates ingestion" do
    service.upsert_products

    expect(Contract.exists?(product_id: "GOL-29JUL26-CDE")).to be false
  end

  it "leaves margin nil when the API payload genuinely carries none, rather than guessing" do
    gold = existing_gold
    allow(service).to receive(:list_products)
      .and_return([{"product_id" => "GOL-29JUL26-CDE", "trading_disabled" => false}])

    service.upsert_products

    expect(gold.reload.intraday_margin_rate_long).to be_nil
  end
end
