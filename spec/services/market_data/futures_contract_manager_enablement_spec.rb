# frozen_string_literal: true

require "rails_helper"

# The other path that granted enablement with no decision behind it.
#
# `discover_current_month_contract` GUESSES a product id from a date rule (last
# Friday of the month), never asks the API whether it exists, and writes
# `enabled: true, status: "online"`. Two consequences:
#
#   1. It is reached from `current_month_contract`, whose lookup is scoped to
#      `Contract.enabled`. So disabling a contract made the lookup miss, which
#      called discovery, which re-enabled the very row the operator had just
#      turned off — on the next realtime cycle, silently.
#   2. A fabricated row carries no future_product_details and therefore no
#      margin rates, which is why enabled futures contracts exist with NULL
#      intraday_margin_rate_long and Trading::LiquidationBuffer unarmed on them.
#
# Discovery may still bring a NEW month into the data pipeline. It may not
# overturn a decision already recorded on an existing row.
RSpec.describe MarketData::FuturesContractManager, "discovery vs enablement" do
  subject(:manager) { described_class.new(logger: Logger.new(File::NULL)) }

  def current_month_id(asset) = manager.generate_current_month_contract_id(asset)

  it "brings a newly-discovered month into the data pipeline" do
    manager.discover_current_month_contract("BTC")

    expect(Contract.find_by(product_id: current_month_id("BTC")).enabled).to be true
  end

  it "does not re-enable a contract an operator disabled" do
    id = current_month_id("BTC")
    Contract.create!(product_id: id, base_currency: "BTC", quote_currency: "USD",
      expiration_date: Contract.parse_expiry_date(id), contract_type: "CDE", enabled: false)

    manager.discover_current_month_contract("BTC")

    expect(Contract.find_by(product_id: id).enabled).to be false
  end

  it "does not re-enable through the lookup path either" do
    id = current_month_id("BTC")
    Contract.create!(product_id: id, base_currency: "BTC", quote_currency: "USD",
      expiration_date: Contract.parse_expiry_date(id), contract_type: "CDE", enabled: false)

    manager.current_month_contract("BTC")

    expect(Contract.find_by(product_id: id).enabled).to be false
  end

  it "does not overwrite margin rates already ingested from the API" do
    id = current_month_id("BTC")
    Contract.create!(product_id: id, base_currency: "BTC", quote_currency: "USD",
      expiration_date: Contract.parse_expiry_date(id), contract_type: "CDE", enabled: true,
      intraday_margin_rate_long: 0.1)

    manager.discover_current_month_contract("BTC")

    expect(Contract.find_by(product_id: id).intraday_margin_rate_long.to_f).to eq(0.1)
  end
end
