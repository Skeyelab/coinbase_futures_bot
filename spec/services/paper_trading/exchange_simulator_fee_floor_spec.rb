# frozen_string_literal: true

require "rails_helper"

# Issue #471: Coinbase US futures charge ~0.02%/contract with a $0.15/contract
# MINIMUM per side. On a ~$100-notional nano the proportional fee is ~$0.02 and
# the floor is $0.15 — the floor is the dominant cost term, not a rounding
# detail, and pricing it as pure bps understates the true cost ~7.5x.
RSpec.describe PaperTrading::ExchangeSimulator, "per-contract fee floor" do
  let(:candle) { Struct.new(:timestamp, :high, :low, :close).new(Time.utc(2026, 6, 1), 105.0, 95.0, 100.0) }

  # One $100-notional contract at 0.02%: proportional = $0.02, floor = $0.15.
  def nano_sim(**overrides)
    described_class.new(starting_equity_usd: 10_000.0, fee_rate: 0.0002, slippage: 0.0,
      per_contract_fee: 0.15, contract_size_usd: 100.0, **overrides)
  end

  def fill_one(sim)
    id = sim.place_limit(symbol: "NOL-TEST", side: :buy, price: 100.0, quantity: 1.0)
    sim.on_candle(candle)
    sim.fills.find { |f| f[:order_id] == id }
  end

  it "charges the per-contract floor when the proportional fee falls under it" do
    fee = fill_one(nano_sim)[:fee]

    expect(fee).to be_within(1e-9).of(0.15)
  end

  it "leaves the proportional fee alone when it already exceeds the floor" do
    # 3 bps on $100 = $0.03 — still under $0.15 — so raise notional instead:
    # a $10,000 contract at 3 bps pays $3.00, far above the floor.
    sim = described_class.new(starting_equity_usd: 100_000.0, fee_rate: 0.0003, slippage: 0.0,
      per_contract_fee: 0.15, contract_size_usd: 10_000.0)
    big = Struct.new(:timestamp, :high, :low, :close).new(Time.utc(2026, 6, 1), 10_050.0, 9_950.0, 10_000.0)
    id = sim.place_limit(symbol: "BIP-TEST", side: :buy, price: 10_000.0, quantity: 1.0)
    sim.on_candle(big)
    fee = sim.fills.find { |f| f[:order_id] == id }[:fee]

    expect(fee).to be_within(1e-9).of(3.0)
  end

  # A perp backtest passes no floor and must be completely unaffected.
  it "applies no floor when the venue does not have one" do
    sim = described_class.new(starting_equity_usd: 10_000.0, fee_rate: 0.0003, slippage: 0.0,
      per_contract_fee: nil, contract_size_usd: 100.0)
    id = sim.place_limit(symbol: "BIP-TEST", side: :buy, price: 100.0, quantity: 1.0)
    sim.on_candle(candle)
    fee = sim.fills.find { |f| f[:order_id] == id }[:fee]

    expect(fee).to be_within(1e-9).of(100.0 * 0.0003)
  end

  it "scales the floor with contract count rather than charging it once" do
    # 3 contracts of $100 each = $300 notional -> floor is 3 x $0.15.
    sim = nano_sim
    id = sim.place_limit(symbol: "NOL-TEST", side: :buy, price: 100.0, quantity: 3.0)
    sim.on_candle(candle)
    fee = sim.fills.find { |f| f[:order_id] == id }[:fee]

    expect(fee).to be_within(1e-9).of(0.45)
  end

  # The floor binds on the exit side too; a round trip pays it twice, which is
  # what makes small-notional contracts structurally expensive (ADR 0002).
  it "charges the floor on both sides of a round trip, matching CostModel" do
    sim = nano_sim
    sim.place_limit(symbol: "NOL-TEST", side: :buy, price: 100.0, quantity: 1.0, tp: 101.0)
    sim.on_candle(candle)
    sim.on_candle(Struct.new(:timestamp, :high, :low, :close).new(Time.utc(2026, 6, 1, 1), 102.0, 100.5, 101.0))

    total_fees = sim.fills.sum { |f| f[:fee] }
    expected = CostModel.round_trip_cost(entry_price: 100.0, exit_price: 101.0, quantity: 1.0,
      fee_rate: 0.0002, contracts: 1.0)

    expect(total_fees).to be_within(1e-9).of(expected)
    expect(total_fees).to be_within(1e-9).of(0.30)
  end
end
