# frozen_string_literal: true

require "rails_helper"

# The scope was `product_id LIKE "#{asset}%"`, which only matches when the
# product id STARTS WITH the asset name — true for spot (BTC-USD) and false for
# every futures contract, because Coinbase names them by contract code:
#
#   OIL -> NOL-*   BTC -> BIT-*/BIP-*   ETH -> ET-*/ETP-*   XRP -> XPP-*
#
# So Position.open.by_asset("OIL").count returned 0 while three OIL positions
# were open, and RapidSignalEvaluationJob's per-asset concurrent cap
# (config/asset_sizing.yml, OIL max_concurrent: 1) never bound. Observed live:
# three concurrent NOL shorts at 20:18, 20:38 and 20:57.
#
# The mapping is already in the DB — contracts.base_currency is synced from the
# Coinbase products API — so it is resolved rather than hardcoded.
RSpec.describe Position, ".by_asset" do
  before do
    Position.destroy_all
    Contract.where(product_id: %w[NOL-19AUG26-CDE BIP-20DEC30-CDE BIT-31JUL26-CDE BTC-USD]).delete_all
    create(:contract, product_id: "NOL-19AUG26-CDE", base_currency: "OIL")
    create(:contract, product_id: "BIP-20DEC30-CDE", base_currency: "BTC")
    create(:contract, product_id: "BIT-31JUL26-CDE", base_currency: "BTC")
    create(:contract, product_id: "BTC-USD", base_currency: "BTC")
  end

  def pos!(product_id)
    create(:position, product_id: product_id, status: "OPEN")
  end

  # The bug, stated directly.
  it "matches a futures contract whose code differs from the asset name" do
    pos!("NOL-19AUG26-CDE")

    expect(described_class.open.by_asset("OIL").count).to eq(1)
  end

  it "counts every contract for an asset, dated and perp alike" do
    pos!("BIT-31JUL26-CDE")
    pos!("BIP-20DEC30-CDE")

    expect(described_class.open.by_asset("BTC").count).to eq(2)
  end

  it "still matches spot, which the old prefix match handled" do
    pos!("BTC-USD")

    expect(described_class.open.by_asset("BTC").count).to eq(1)
  end

  it "does not bleed across assets" do
    pos!("NOL-19AUG26-CDE")
    pos!("BIP-20DEC30-CDE")

    expect(described_class.open.by_asset("OIL").count).to eq(1)
    expect(described_class.open.by_asset("BTC").count).to eq(1)
  end

  # A position can outlive its Contract row (expired, or synced away). Falling
  # back to the prefix match keeps those visible rather than silently dropping
  # exposure from the count — the same failure mode in a new place.
  it "still matches when no Contract row exists, via the legacy prefix" do
    Contract.where(product_id: "BTC-USD").delete_all
    pos!("BTC-USD")

    expect(described_class.open.by_asset("BTC").count).to eq(1)
  end

  it "is empty for an asset with nothing open" do
    expect(described_class.open.by_asset("SILVER").count).to eq(0)
  end
end
