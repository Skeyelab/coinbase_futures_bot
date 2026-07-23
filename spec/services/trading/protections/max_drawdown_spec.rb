# frozen_string_literal: true

require "rails_helper"

# Issue #401 (ADR 0003): equity-drawdown circuit breaker. When drawdown from the
# recent equity peak exceeds a ceiling, write a GLOBAL ProtectionLock halting all
# new entries. Drawdown-from-peak IS the equity-curve drawdown; pure decision so
# it's table-testable and identical live (rolling peak) and backtest (curve peak).
RSpec.describe Trading::Protections::MaxDrawdown, type: :service do
  let(:store) { Trading::ProtectionLock::MemoryStore.new }
  let(:now) { Time.utc(2026, 1, 1, 12, 0, 0) }

  subject(:guard) { described_class.new(ceiling: 0.10, lock_ttl_seconds: 1800) }

  describe "#drawdown" do
    it "is the fractional drop from peak to current" do
      expect(guard.drawdown(peak: 10_000.0, current: 9_000.0)).to be_within(1e-9).of(0.10)
      expect(guard.drawdown(peak: 10_000.0, current: 10_000.0)).to eq(0.0)
    end

    it "is 0 for a new high or a non-positive peak" do
      expect(guard.drawdown(peak: 10_000.0, current: 11_000.0)).to eq(0.0)
      expect(guard.drawdown(peak: 0.0, current: 5_000.0)).to eq(0.0)
    end
  end

  describe "#evaluate" do
    it "writes a global halt once drawdown exceeds the ceiling" do
      guard.evaluate(peak: 10_000.0, current: 8_500.0, now: now, store: store) # 15% > 10%

      expect(Trading::Protections.blocked?(symbol: "ANY-SYM", side: "long", now: now, store: store)).to be true
      expect(Trading::Protections.blocked?(symbol: "OTHER", side: "short", now: now, store: store)).to be true
      lock = Trading::ProtectionLock.active(now: now, store: store).first
      expect(lock["scope"]).to eq("global")
      expect(lock["source"]).to eq("MaxDrawdown")
    end

    it "does not halt below the ceiling" do
      guard.evaluate(peak: 10_000.0, current: 9_500.0, now: now, store: store) # 5% < 10%
      expect(Trading::Protections.blocked?(symbol: "ANY", side: "long", now: now, store: store)).to be false
    end

    it "the halt expires after lock_ttl_seconds (recovery window)" do
      guard.evaluate(peak: 10_000.0, current: 8_000.0, now: now, store: store)
      expect(Trading::Protections.blocked?(symbol: "ANY", side: "long", now: now + 1799, store: store)).to be true
      expect(Trading::Protections.blocked?(symbol: "ANY", side: "long", now: now + 1801, store: store)).to be false
    end
  end

  it "is disabled with a non-positive ceiling" do
    g = described_class.new(ceiling: 0)
    expect(g.enabled?).to be false
    g.evaluate(peak: 10_000.0, current: 1.0, now: now, store: store)
    expect(Trading::Protections.blocked?(symbol: "ANY", side: "long", now: now, store: store)).to be false
  end
end
