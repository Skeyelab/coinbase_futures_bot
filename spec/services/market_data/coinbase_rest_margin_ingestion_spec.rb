# frozen_string_literal: true

require "rails_helper"

# Margin-rate ingestion (task: LiquidationBuffer assumed-leverage gap).
#
# Trading::LiquidationBuffer computed liquidation from an assumed 10x because
# nothing stored real margin. Coinbase returns it on every products call under
# future_product_details, and upsert_products was dropping it. Without these
# columns the buffer cannot arm, so this is the data path the whole fix rests on.
#
# Shapes below are real, read from list_products on 2026-07-27.
RSpec.describe MarketData::CoinbaseRest do
  subject(:service) { described_class.new }

  let(:products) do
    [
      {
        "product_id" => "PAU-20DEC30-CDE", "trading_disabled" => false,
        "future_product_details" => {
          "intraday_margin_rate" => {"long_margin_rate" => "0.049977", "short_margin_rate" => "0.0500181"},
          "overnight_margin_rate" => {"long_margin_rate" => "0.077125", "short_margin_rate" => "0.082375"}
        }
      },
      {
        "product_id" => "BIP-20DEC30-CDE", "trading_disabled" => false,
        "future_product_details" => {
          "intraday_margin_rate" => {"long_margin_rate" => "0.1000185", "short_margin_rate" => "0.1000008"},
          "overnight_margin_rate" => {"long_margin_rate" => "0.245625", "short_margin_rate" => "0.306375"}
        }
      },
      # A product whose payload carries no margin block at all.
      {"product_id" => "NOL-19JUN26-CDE", "trading_disabled" => false}
    ]
  end

  before do
    allow(service).to receive(:list_products).and_return(products)
    allow(Contract).to receive(:upsert)
    allow(Rails.logger).to receive(:info)
  end

  def upserted
    service.upsert_products
    rows = {}
    expect(Contract).to have_received(:upsert) { |attrs, **_| rows[attrs[:product_id]] = attrs }.at_least(:once)
    rows
  end

  it "persists per-side intraday margin so the buffer can arm on real leverage" do
    row = upserted["PAU-20DEC30-CDE"]

    expect(row[:intraday_margin_rate_long].to_f).to be_within(1e-9).of(0.049977)
    expect(row[:intraday_margin_rate_short].to_f).to be_within(1e-9).of(0.0500181)
  end

  it "persists overnight margin too, since it differs sharply from intraday" do
    row = upserted["BIP-20DEC30-CDE"]

    expect(row[:overnight_margin_rate_long].to_f).to be_within(1e-9).of(0.245625)
    expect(row[:overnight_margin_rate_short].to_f).to be_within(1e-9).of(0.306375)
  end

  # nil, not 0 and not a guess: LiquidationBuffer reads a missing rate as
  # "unknown" and refuses to arm, which is the fail-closed direction.
  it "leaves margin nil when the payload carries none" do
    row = upserted["NOL-19JUN26-CDE"]

    expect(row[:intraday_margin_rate_long]).to be_nil
    expect(row[:intraday_margin_rate_short]).to be_nil
  end
end
