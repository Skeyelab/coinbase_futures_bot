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

  # A halt is a STATE, not an event per evaluation cycle. The live monitor runs
  # every ~30s and alerts once per lock returned here, so re-adding a lock while
  # the same breach persists produced a Slack warning every 30s and stacked 12
  # identical locks for one condition — observed 2026-07-28. An operator who
  # learns to mute that channel will also miss the liquidation warning.
  describe "re-evaluating while already halted" do
    it "does not stack a second lock for the same ongoing breach" do
      guard.evaluate(peak: 10_000.0, current: 8_000.0, now: now, store: store)
      guard.evaluate(peak: 10_000.0, current: 7_900.0, now: now + 30, store: store)

      drawdown_locks = Trading::ProtectionLock.active(now: now + 30, store: store)
        .select { |l| l["source"] == described_class::SOURCE }
      expect(drawdown_locks.size).to eq(1)
    end

    it "returns no new lock, so the caller raises no fresh alert" do
      first = guard.evaluate(peak: 10_000.0, current: 8_000.0, now: now, store: store)
      second = guard.evaluate(peak: 10_000.0, current: 7_900.0, now: now + 30, store: store)

      expect(first.size).to eq(1)
      expect(second).to be_empty
    end

    it "still halts, so suppressing the alert never un-protects the bot" do
      guard.evaluate(peak: 10_000.0, current: 8_000.0, now: now, store: store)
      guard.evaluate(peak: 10_000.0, current: 7_900.0, now: now + 30, store: store)

      expect(Trading::Protections.blocked?(symbol: "ANY", side: "long", now: now + 30, store: store)).to be true
    end

    it "alerts again on a fresh breach after the previous lock expired" do
      guard.evaluate(peak: 10_000.0, current: 8_000.0, now: now, store: store)
      later = now + 1801 # past lock_ttl_seconds

      expect(guard.evaluate(peak: 10_000.0, current: 8_000.0, now: later, store: store).size).to eq(1)
    end
  end

  it "is disabled with a non-positive ceiling" do
    g = described_class.new(ceiling: 0)
    expect(g.enabled?).to be false
    g.evaluate(peak: 10_000.0, current: 1.0, now: now, store: store)
    expect(Trading::Protections.blocked?(symbol: "ANY", side: "long", now: now, store: store)).to be false
  end
end
