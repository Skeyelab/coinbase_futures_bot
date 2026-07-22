# frozen_string_literal: true

require "rails_helper"

# Issue #397 (ADR 0003): Trading::Protections evaluates active ProtectionLocks
# against a candidate (symbol, side) entry. This is the single seam the realtime
# evaluator and backtest consult before accepting an entry.
RSpec.describe Trading::Protections, type: :service do
  after { Trading::ProtectionLock.clear! }

  it "does not block when there are no locks" do
    expect(described_class.blocked?(symbol: "BTC-PERP", side: "long")).to be false
  end

  it "blocks a symbol-scoped both-sides lock for either side of that symbol" do
    Trading::ProtectionLock.add(scope: "symbol", symbol: "BTC-PERP", side: "both",
      source: "CooldownPeriod", expires_at: 10.minutes.from_now)

    expect(described_class.blocked?(symbol: "BTC-PERP", side: "long")).to be true
    expect(described_class.blocked?(symbol: "BTC-PERP", side: "short")).to be true
  end

  it "does not block a different symbol" do
    Trading::ProtectionLock.add(scope: "symbol", symbol: "BTC-PERP", side: "both",
      source: "CooldownPeriod", expires_at: 10.minutes.from_now)

    expect(described_class.blocked?(symbol: "ETH-PERP", side: "long")).to be false
  end

  it "blocks only the matching side for a side-specific lock" do
    Trading::ProtectionLock.add(scope: "symbol", symbol: "BTC-PERP", side: "long",
      source: "StoplossGuard", expires_at: 10.minutes.from_now)

    expect(described_class.blocked?(symbol: "BTC-PERP", side: "long")).to be true
    expect(described_class.blocked?(symbol: "BTC-PERP", side: "short")).to be false
  end

  it "blocks any symbol and side for a global lock" do
    Trading::ProtectionLock.add(scope: "global", side: "both",
      source: "MaxDrawdown", expires_at: 10.minutes.from_now)

    expect(described_class.blocked?(symbol: "BTC-PERP", side: "long")).to be true
    expect(described_class.blocked?(symbol: "ETH-PERP", side: "short")).to be true
  end

  it "does not block when the only matching lock has expired" do
    Trading::ProtectionLock.add(scope: "symbol", symbol: "BTC-PERP", side: "both",
      source: "CooldownPeriod", expires_at: 1.minute.ago)

    expect(described_class.blocked?(symbol: "BTC-PERP", side: "long")).to be false
  end

  it "exposes the reason of the blocking lock" do
    Trading::ProtectionLock.add(scope: "symbol", symbol: "BTC-PERP", side: "both",
      source: "CooldownPeriod", reason: "cooldown after exit", expires_at: 10.minutes.from_now)

    expect(described_class.block_reason(symbol: "BTC-PERP", side: "long"))
      .to include("CooldownPeriod")
    expect(described_class.block_reason(symbol: "ETH-PERP", side: "long")).to be_nil
  end
end
