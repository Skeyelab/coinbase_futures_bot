# frozen_string_literal: true

require "rails_helper"

# Issue #397 (ADR 0003): durable protection locks, BotRuntimeStat-backed
# (same pattern as TradingHalt / SymbolSuspension) so every process — realtime
# loop, worker, CLI, backtest — sees the same active locks.
RSpec.describe Trading::ProtectionLock, type: :service do
  it "adds a lock that appears in .active" do
    expect(described_class.active).to be_empty

    described_class.add(
      scope: "symbol",
      symbol: "BTC-PERP",
      side: "both",
      source: "CooldownPeriod",
      reason: "cooldown after exit",
      expires_at: 10.minutes.from_now
    )

    active = described_class.active
    expect(active.size).to eq(1)
    lock = active.first
    expect(lock["scope"]).to eq("symbol")
    expect(lock["symbol"]).to eq("BTC-PERP")
    expect(lock["side"]).to eq("both")
    expect(lock["source"]).to eq("CooldownPeriod")
    expect(lock["reason"]).to eq("cooldown after exit")
  end

  it "excludes expired locks from .active (TTL auto-expiry)" do
    described_class.add(scope: "global", source: "MaxDrawdown", expires_at: 1.hour.ago)

    expect(described_class.active).to be_empty
  end

  it "keeps unexpired locks while dropping expired ones" do
    described_class.add(scope: "symbol", symbol: "ETH-PERP", source: "StoplossGuard", expires_at: 1.hour.ago)
    described_class.add(scope: "symbol", symbol: "BTC-PERP", source: "CooldownPeriod", expires_at: 5.minutes.from_now)

    active = described_class.active
    expect(active.map { |l| l["symbol"] }).to contain_exactly("BTC-PERP")
  end

  it "is durable across instances (BotRuntimeStat-backed)" do
    described_class.add(scope: "global", source: "MaxDrawdown", expires_at: 10.minutes.from_now)

    expect(BotRuntimeStat.find_by(key: described_class::STORE_KEY)).to be_present
    expect(Trading::ProtectionLock.active.size).to eq(1)
  end

  it "clear! removes all locks" do
    described_class.add(scope: "global", source: "MaxDrawdown", expires_at: 10.minutes.from_now)
    described_class.clear!

    expect(described_class.active).to be_empty
  end
end
