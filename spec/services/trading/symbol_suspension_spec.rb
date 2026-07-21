# frozen_string_literal: true

require "rails_helper"

# Issue #371: per-symbol trading suspension, durable across processes
# (BotRuntimeStat-backed, same pattern as TradingHalt/DryRun).
RSpec.describe Trading::SymbolSuspension, type: :service do
  it "suspends and resumes a symbol" do
    expect(described_class.suspended?("ETH-USD")).to be false

    described_class.suspend!("ETH-USD", reason: "trailing gross < costs")
    expect(described_class.suspended?("ETH-USD")).to be true
    expect(described_class.suspended?("BTC-USD")).to be false

    described_class.resume!("ETH-USD")
    expect(described_class.suspended?("ETH-USD")).to be false
  end

  it "records reason and timestamp, listable via .all" do
    described_class.suspend!("ET-31JUL26-CDE", reason: "cost bleed")

    entry = described_class.all["ET-31JUL26-CDE"]
    expect(entry["reason"]).to eq("cost bleed")
    expect(Time.parse(entry["suspended_at"])).to be_within(5).of(Time.current)
  end

  it "is durable across service instances (DB-backed)" do
    described_class.suspend!("ETH-USD", reason: "x")
    expect(Trading::SymbolSuspension.suspended?("ETH-USD")).to be true
    expect(BotRuntimeStat.find_by(key: described_class::STORE_KEY)).to be_present
  end

  it "resume of an unsuspended symbol is a no-op" do
    expect { described_class.resume!("NOPE-USD") }.not_to raise_error
  end
end
