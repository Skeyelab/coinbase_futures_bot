# frozen_string_literal: true

require "rails_helper"

# PAXG perp (PAU) ingestion. Gold via the PERP is the viable vehicle — 3 bps
# taker against dated gold's 9, no roll, 24/7, expires 2030 — but it had zero
# candles because nothing ingested it. History has to start accruing before any
# of it can be evaluated (ADR 0002 / 0004: collect while suspended, earn
# enablement on your own data).
RSpec.describe Contract, "PAXG perp ingestion" do
  it "maps the PAU prefix to gold" do
    expect(described_class::PREFIX_TO_BASE_CURRENCY["PAU"]).to eq("PAXG")
  end

  it "parses a PAU product id like any other CDE contract" do
    info = described_class.parse_contract_info("PAU-20DEC30-CDE")

    expect(info[:base_currency]).to eq("PAXG")
    expect(info[:contract_type]).to eq("CDE")
  end

  # The map is the ingestion filter — MarketData::CoinbaseRest#upsert_products
  # builds its allow-list from these keys, so a missing prefix means no candles.
  it "is included in the ingestion filter" do
    expect(described_class::PREFIX_TO_BASE_CURRENCY.keys).to include("PAU")
  end

  # PAXG has no spot pair on the venue; a derived spot list would subscribe to a
  # nonexistent PAXG-USD, which is exactly why that list is curated separately.
  it "does not imply a spot feed" do
    expect(MarketData::RealtimeSubscriptionCatalog::KNOWN_SPOT_PRODUCT_IDS).not_to include("PAXG-USD")
  end

  # Ingesting is not enabling: it must collect while suspended from trading.
  it "resolves as a perp for fee purposes once funding is observed" do
    FundingRate.create!(product_id: "PAU-20DEC30-CDE", funding_time: 1.hour.ago,
      funding_rate: 0.00001, funding_interval_seconds: 3600, observed_at: 1.hour.ago)

    fees = CostModel.fee_for("PAU-20DEC30-CDE")

    expect(CostModel.perp?("PAU-20DEC30-CDE")).to be true
    expect(fees[:taker_rate]).to eq(CostModel.taker_fee_rate)
    expect(fees[:taker_rate]).to be < CostModel.dated_taker_rate
  end
end
