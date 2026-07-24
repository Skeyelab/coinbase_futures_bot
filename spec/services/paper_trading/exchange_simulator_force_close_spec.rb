# frozen_string_literal: true

require "rails_helper"

# Issue #398: force_close lets the backtest engine book a min-ROI time-decay exit
# at an explicit price with an exit reason, independent of the sim's TP/SL pass.
RSpec.describe PaperTrading::ExchangeSimulator, "#force_close" do
  let(:sim) { described_class.new(starting_equity_usd: 10_000.0, fee_rate: 0.0, slippage: 0.0) }
  let(:candle) { Struct.new(:close, :high, :low).new(100.0, 100.0, 100.0) }

  def open_filled_long
    id = sim.place_limit(symbol: "X", side: :buy, price: 100.0, quantity: 1.0, tp: 200.0, sl: 1.0)
    sim.on_candle(candle) # fill the limit
    id
  end

  it "closes a filled position at the given price, realizing PnL and tagging the reason" do
    id = open_filled_long
    expect(sim.orders[id].status).to eq(:filled)

    sim.force_close(id, price: 110.0, reason: :time_decay_roi)

    order = sim.orders[id]
    expect(order.status).to eq(:closed)
    expect(order.exit_reason).to eq(:time_decay_roi)
    expect(sim.equity_usd).to be_within(1e-9).of(10_010.0) # +$10 on 1 unit, 100 -> 110
  end

  it "is a no-op for a non-filled order" do
    id = sim.place_limit(symbol: "X", side: :buy, price: 100.0, quantity: 1.0)
    expect { sim.force_close(id, price: 110.0, reason: :time_decay_roi) }.not_to change(sim, :equity_usd)
    expect(sim.orders[id].status).to eq(:open)
  end
end
