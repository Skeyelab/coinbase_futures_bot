# frozen_string_literal: true

require "rails_helper"

# Two defects in the only automated writer of Trading::SymbolSuspension, both
# of which make it see less than it should.
#
# 1. It filtered `paper: true`. With LIVE_TRADING_CONFIRMED=1 positions are
#    written `paper: false`, so the breaker looked at an empty set and the ONLY
#    automated suspension writer was blind on exactly the runs where a bad
#    symbol costs real money. Trading::LossLimits already gets this right by
#    scoping to the mode in force (`paper: DryRun.active?`).
#
# 2. `trades.size < min_trades` counted ROWS, and since #509 a partial reduce
#    creates its own CLOSED row. Five partial reduces of ONE position therefore
#    satisfied a five-trade minimum, so the breaker could suspend a symbol on a
#    sample of one position — the opposite failure to (1), and the one that
#    stops a working symbol.
RSpec.describe SymbolCircuitBreakerJob, "sees the trades that exist", type: :job do
  before { allow(Trading::ContractSizeResolver).to receive(:for_product).and_return(0.01) }

  def closed_trade(symbol, paper:, pnl: -2.0, ago: 1.day, **extra)
    create(:position, paper: paper, status: "CLOSED", product_id: symbol, pnl: pnl,
      entry_price: 4_000.0, size: 2.0, entry_time: ago.ago - 600, close_time: ago.ago, **extra)
  end

  describe "the mode in force" do
    it "sees LIVE trades when dry-run is off" do
      allow(DryRun).to receive(:active?).and_return(false)
      6.times { closed_trade("ETH-USD", paper: false) }

      ClimateControl.modify(BACKTEST_TAKER_FEE_RATE: nil, TAKER_FEE_RATE: nil) { described_class.new.perform }

      expect(Trading::SymbolSuspension.explicitly_suspended?("ETH-USD")).to be true
    end

    it "ignores paper trades when dry-run is off, so a paper drill cannot suspend a live symbol" do
      allow(DryRun).to receive(:active?).and_return(false)
      6.times { closed_trade("ETH-USD", paper: true) }

      ClimateControl.modify(BACKTEST_TAKER_FEE_RATE: nil, TAKER_FEE_RATE: nil) { described_class.new.perform }

      expect(Trading::SymbolSuspension.explicitly_suspended?("ETH-USD")).to be false
    end

    it "sees paper trades when dry-run is on" do
      allow(DryRun).to receive(:active?).and_return(true)
      6.times { closed_trade("ETH-USD", paper: true) }

      ClimateControl.modify(BACKTEST_TAKER_FEE_RATE: nil, TAKER_FEE_RATE: nil) { described_class.new.perform }

      expect(Trading::SymbolSuspension.explicitly_suspended?("ETH-USD")).to be true
    end
  end

  describe "the sample size" do
    before { allow(DryRun).to receive(:active?).and_return(true) }

    it "counts one position closed in six slices as one trade, not six" do
      parent = create(:position, paper: true, status: "OPEN", product_id: "ETH-USD",
        entry_price: 4_000.0, size: 12.0, entry_time: 2.days.ago)
      6.times { closed_trade("ETH-USD", paper: true, parent_position_id: parent.id) }

      ClimateControl.modify(BACKTEST_TAKER_FEE_RATE: nil, TAKER_FEE_RATE: nil) { described_class.new.perform }

      expect(Trading::SymbolSuspension.explicitly_suspended?("ETH-USD")).to be false
    end

    it "still acts on six genuinely distinct losing positions" do
      6.times { closed_trade("ETH-USD", paper: true) }

      ClimateControl.modify(BACKTEST_TAKER_FEE_RATE: nil, TAKER_FEE_RATE: nil) { described_class.new.perform }

      expect(Trading::SymbolSuspension.explicitly_suspended?("ETH-USD")).to be true
    end
  end

  describe "Position#close_partial!" do
    it "links the closed slice back to the position it came from" do
      parent = create(:position, status: "OPEN", product_id: "NOL-30SEP26-CDE", side: "LONG",
        entry_price: 80.0, size: 4.0, entry_time: 1.hour.ago)

      portion = parent.close_partial!(1.0, 81.0)

      expect(portion.parent_position_id).to eq(parent.id)
      expect(parent.reload.size).to eq(3.0)
    end
  end
end
