# frozen_string_literal: true

require "rails_helper"

# Issue #371: auto-suspend any symbol whose trailing gross edge no longer
# covers its estimated round-trip costs. Realized-PnL complement to the
# ex-ante cost gate (#358). Resume is always manual.
RSpec.describe SymbolCircuitBreakerJob, type: :job do
  before do
    allow(Trading::ContractSizeResolver).to receive(:for_product).and_return(0.01)
  end

  def close_paper_trade(symbol, pnl:, entry_price: 4_000.0, size: 2.0, ago: 1.day)
    create(:position, paper: true, status: "CLOSED", product_id: symbol, pnl: pnl,
      entry_price: entry_price, size: size, entry_time: ago.ago - 600, close_time: ago.ago)
  end

  it "suspends a symbol whose trailing gross PnL is below estimated costs" do
    6.times { close_paper_trade("ETH-USD", pnl: -2.0) }

    ClimateControl.modify(BACKTEST_TAKER_FEE_RATE: nil, TAKER_FEE_RATE: nil) do
      described_class.new.perform
    end

    expect(Trading::SymbolSuspension.suspended?("ETH-USD")).to be true
    expect(Trading::SymbolSuspension.all["ETH-USD"]["reason"]).to match(/gross.*cost/i)
  end

  it "leaves a symbol alone when gross covers costs" do
    6.times { close_paper_trade("BTC-USD", pnl: 5.0) }

    described_class.new.perform

    expect(Trading::SymbolSuspension.suspended?("BTC-USD")).to be false
  end

  it "does not act below the minimum sample size" do
    3.times { close_paper_trade("ETH-USD", pnl: -50.0) }

    described_class.new.perform

    expect(Trading::SymbolSuspension.suspended?("ETH-USD")).to be false
  end

  it "ignores trades outside the trailing window and never auto-resumes" do
    6.times { close_paper_trade("ETH-USD", pnl: -10.0, ago: 10.days) }
    Trading::SymbolSuspension.suspend!("SOL-USD", reason: "manual")

    described_class.new.perform

    expect(Trading::SymbolSuspension.suspended?("ETH-USD")).to be false
    expect(Trading::SymbolSuspension.suspended?("SOL-USD")).to be true
  end
end
