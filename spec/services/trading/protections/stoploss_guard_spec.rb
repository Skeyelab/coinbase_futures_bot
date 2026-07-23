# frozen_string_literal: true

require "rails_helper"

# Issue #400 (ADR 0003): halt entries after a cluster of losing exits (a bad
# regime). Side-aware (only_per_side) and scoped per-symbol or global. Built on
# the #397 ProtectionLock substrate; source-agnostic — the caller supplies the
# recent losing exits (Position query live, trade list in backtest), so the
# decision is identical in both.
#
# "stop-out" = a losing close (pnl < 0). Position close reason isn't persisted;
# a cluster of losses is the regime signal the guard is meant to catch.
RSpec.describe Trading::Protections::StoplossGuard, type: :service do
  let(:store) { Trading::ProtectionLock::MemoryStore.new }
  let(:now) { Time.utc(2026, 1, 1, 12, 0, 0) }

  def exit_at(side:, mins_ago:)
    {side: side, at: now - mins_ago * 60}
  end

  describe "per-side (only_per_side: true)" do
    subject(:guard) do
      described_class.new(threshold: 3, lookback_seconds: 3600, only_per_side: true,
        scope: "symbol", lock_ttl_seconds: 1800)
    end

    it "locks only the offending side after K losing exits in the window" do
      exits = [exit_at(side: "long", mins_ago: 5), exit_at(side: "long", mins_ago: 10),
        exit_at(side: "long", mins_ago: 20)]

      guard.evaluate(symbol: "BTC-PERP", exits: exits, now: now, store: store)

      expect(Trading::Protections.blocked?(symbol: "BTC-PERP", side: "long", now: now, store: store)).to be true
      expect(Trading::Protections.blocked?(symbol: "BTC-PERP", side: "short", now: now, store: store)).to be false
    end

    it "does not lock below the threshold" do
      exits = [exit_at(side: "long", mins_ago: 5), exit_at(side: "long", mins_ago: 10)]
      guard.evaluate(symbol: "BTC-PERP", exits: exits, now: now, store: store)
      expect(Trading::Protections.blocked?(symbol: "BTC-PERP", side: "long", now: now, store: store)).to be false
    end

    it "ignores exits older than the lookback window" do
      exits = [exit_at(side: "long", mins_ago: 5), exit_at(side: "long", mins_ago: 10),
        exit_at(side: "long", mins_ago: 90)] # 90m > 60m lookback
      guard.evaluate(symbol: "BTC-PERP", exits: exits, now: now, store: store)
      expect(Trading::Protections.blocked?(symbol: "BTC-PERP", side: "long", now: now, store: store)).to be false
    end

    it "writes a lock that expires after lock_ttl_seconds" do
      exits = Array.new(3) { |i| exit_at(side: "short", mins_ago: i + 1) }
      guard.evaluate(symbol: "BTC-PERP", exits: exits, now: now, store: store)

      expect(Trading::Protections.blocked?(symbol: "BTC-PERP", side: "short", now: now + 1799, store: store)).to be true
      expect(Trading::Protections.blocked?(symbol: "BTC-PERP", side: "short", now: now + 1801, store: store)).to be false
    end
  end

  describe "combined + global scope (only_per_side: false, scope: global)" do
    subject(:guard) do
      described_class.new(threshold: 3, lookback_seconds: 3600, only_per_side: false,
        scope: "global", lock_ttl_seconds: 1800)
    end

    it "locks both sides across all symbols once total losses hit K" do
      exits = [exit_at(side: "long", mins_ago: 5), exit_at(side: "short", mins_ago: 10),
        exit_at(side: "long", mins_ago: 15)]

      guard.evaluate(symbol: "BTC-PERP", exits: exits, now: now, store: store)

      expect(Trading::Protections.blocked?(symbol: "ETH-PERP", side: "long", now: now, store: store)).to be true
      expect(Trading::Protections.blocked?(symbol: "ETH-PERP", side: "short", now: now, store: store)).to be true
    end
  end

  it "is disabled (never locks) with a non-positive threshold" do
    guard = described_class.new(threshold: 0, lookback_seconds: 3600)
    expect(guard.enabled?).to be false
    guard.evaluate(symbol: "BTC-PERP", exits: [exit_at(side: "long", mins_ago: 1)] * 5, now: now, store: store)
    expect(Trading::Protections.blocked?(symbol: "BTC-PERP", side: "long", now: now, store: store)).to be false
  end
end
