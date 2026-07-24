# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trading::FeeTruth, type: :service do
  # Multiplier of 1 keeps notional = price * contracts so effective rates are
  # exact in these tests; the real resolver is injected in production.
  let(:resolver) { ->(_product, **) { 1.0 } }

  def client(authenticated: true, fills: [])
    instance_double(Trading::CoinbasePositions, authenticated?: authenticated, list_fills: fills)
  end

  def fill(product:, commission:, price: "100", size: "1", liquidity: "TAKER", side: "BUY")
    {"product_id" => product, "liquidity_indicator" => liquidity, "side" => side,
     "price" => price, "size" => size, "commission" => commission, "trade_time" => "2026-07-23T00:00:00Z"}
  end

  it "reports not_authenticated without hitting the API" do
    result = described_class.new(client: client(authenticated: false), resolver: resolver).call
    expect(result[:status]).to eq("not_authenticated")
  end

  it "reports zero perp fills and no drift when only dated/spot fills exist" do
    result = described_class.new(
      client: client(fills: [fill(product: "GOL-25NOV25-CDE", price: "3700", commission: "0.80")]),
      resolver: resolver
    ).call

    expect(result[:status]).to eq("ok")
    expect(result[:perp_fills]).to eq(0)
    expect(result[:perp_taker_drift][:status]).to eq("no_perp_fills")
    expect(result[:by_liquidity]["TAKER"][:avg_commission_per_contract]).to be_within(1e-9).of(0.80)
  end

  it "flags perp-taker drift when real commissions diverge from the model default" do
    result = described_class.new(
      client: client(fills: [fill(product: "BIP-PERP", commission: "0.90")]), resolver: resolver
    ).call

    expect(result[:perp_fills]).to eq(1)
    drift = result[:perp_taker_drift]
    expect(drift[:status]).to eq("drift")
    expect(drift[:observed_rate]).to be_within(1e-9).of(0.009) # 90 bps vs 3 bps model
    expect(drift[:model_rate]).to eq(CostModel.taker_fee_rate)
  end

  it "reports within_tolerance when perp commissions match the model" do
    ClimateControl.modify(BACKTEST_TAKER_FEE_RATE: nil, TAKER_FEE_RATE: nil) do
      result = described_class.new(
        client: client(fills: [fill(product: "BIP-PERP", commission: "0.03")]), resolver: resolver
      ).call

      expect(result[:perp_taker_drift][:status]).to eq("within_tolerance")
      expect(result[:perp_taker_drift][:observed_rate]).to be_within(1e-9).of(0.0003)
    end
  end

  it "computes per-contract commission from multi-contract fills" do
    result = described_class.new(
      client: client(fills: [fill(product: "BIP-PERP", commission: "1.50", size: "3")]), resolver: resolver
    ).call
    # $1.50 / 3 contracts = $0.50 per contract.
    expect(result[:by_liquidity]["TAKER"][:avg_commission_per_contract]).to be_within(1e-9).of(0.50)
  end
end
