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

  # A side-scoped lock is written downcased ("long"/"short") by whichever
  # protection counted it. The candidate side is spelled however the caller's
  # own layer spells sides: Position#side is %w[LONG SHORT], an order side is
  # "BUY"/"SELL", a strategy signal is :long. Every one of those names the same
  # direction, so every one must hit the same lock. The specs above only ever
  # read back the exact string they wrote, which is why a raw string compare
  # looked correct while it silently permitted the entries it was blocking.
  it "blocks a side-scoped lock however the candidate side is spelled" do
    Trading::ProtectionLock.add(scope: "symbol", symbol: "BTC-PERP", side: "long",
      source: "StoplossGuard", expires_at: 10.minutes.from_now)

    ["long", "LONG", "Long", :long, "buy", "BUY", :buy].each do |side|
      expect(described_class.blocked?(symbol: "BTC-PERP", side: side))
        .to be(true), "expected a long lock to block candidate side #{side.inspect}"
    end

    ["short", "SHORT", :short, "sell", "SELL", :sell].each do |side|
      expect(described_class.blocked?(symbol: "BTC-PERP", side: side))
        .to be(false), "expected a long lock to leave candidate side #{side.inspect} alone"
    end
  end

  it "blocks a short lock for SHORT and SELL alike" do
    Trading::ProtectionLock.add(scope: "symbol", symbol: "BTC-PERP", side: "short",
      source: "StoplossGuard", expires_at: 10.minutes.from_now)

    ["short", "SHORT", :short, "sell", "SELL"].each do |side|
      expect(described_class.blocked?(symbol: "BTC-PERP", side: side))
        .to be(true), "expected a short lock to block candidate side #{side.inspect}"
    end
    expect(described_class.blocked?(symbol: "BTC-PERP", side: "LONG")).to be false
  end

  it "names the blocking lock's reason regardless of how the side is spelled" do
    Trading::ProtectionLock.add(scope: "symbol", symbol: "BTC-PERP", side: "long",
      source: "StoplossGuard", reason: "4+ losing exits in 60m", expires_at: 10.minutes.from_now)

    expect(described_class.block_reason(symbol: "BTC-PERP", side: "LONG"))
      .to include("StoplossGuard", "4+ losing exits")
  end

  # A side nobody can parse must not silently read as some side. It is neither
  # long nor short (SideNormalizer.long?/.short? are not complements), so it
  # matches no direction-scoped lock — and, just as importantly, it does not
  # match the OPPOSITE direction's lock either, which is the failure a
  # `!long? -> short?` shortcut would produce.
  it "does not match a side-scoped lock with an unparseable candidate side" do
    Trading::ProtectionLock.add(scope: "symbol", symbol: "BTC-PERP", side: "long",
      source: "StoplossGuard", expires_at: 10.minutes.from_now)

    [nil, "", "sideways", "LNOG", 0].each do |side|
      expect(described_class.blocked?(symbol: "BTC-PERP", side: side))
        .to be(false), "expected unparseable side #{side.inspect} to match no direction"
    end
  end

  # ...but an unparseable side is still bound by the halts that stop everything.
  # Cooldown and MaxDrawdown write side "both", which does not consult the
  # candidate side at all, so a garbage side cannot slip past a full halt.
  it "still blocks an unparseable candidate side under a both-sides lock" do
    Trading::ProtectionLock.add(scope: "global", side: "both",
      source: "MaxDrawdown", expires_at: 10.minutes.from_now)

    expect(described_class.blocked?(symbol: "BTC-PERP", side: nil)).to be true
    expect(described_class.blocked?(symbol: "BTC-PERP", side: "sideways")).to be true
  end

  # A lock whose own side is corrupt matches nothing rather than everything.
  it "does not match a lock whose stored side is unparseable" do
    Trading::ProtectionLock.add(scope: "symbol", symbol: "BTC-PERP", side: "garbage",
      source: "StoplossGuard", expires_at: 10.minutes.from_now)

    expect(described_class.blocked?(symbol: "BTC-PERP", side: "LONG")).to be false
    expect(described_class.blocked?(symbol: "BTC-PERP", side: "garbage")).to be false
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
