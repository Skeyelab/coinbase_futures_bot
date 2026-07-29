# frozen_string_literal: true

require "rails_helper"

# Issue #371: per-symbol trading suspension, durable across processes
# (BotRuntimeStat-backed, same pattern as TradingHalt/DryRun).
#
# `universe_scope` because these examples exercise the permission store itself
# and must see the real fail-closed default from ADR 0006, not the spec-support
# stub that opens the gate for unrelated examples.
RSpec.describe Trading::SymbolSuspension, type: :service, universe_scope: true do
  it "suspends and resumes a symbol" do
    described_class.enable!("ETH-USD", reason: "test fixture")
    expect(described_class.suspended?("ETH-USD")).to be false

    described_class.suspend!("ETH-USD", reason: "trailing gross < costs")
    expect(described_class.suspended?("ETH-USD")).to be true

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

  # Issue #505. Suspension was keyed on product_id but decisions are about an
  # ASSET. Dated contracts roll monthly; each new month synced in as a fresh
  # product_id carrying no suspension, so ETH — suspended for negative EV —
  # silently became tradeable through ET-30OCT26-CDE days after the decision.
  describe "asset-level suspension (#505)" do
    it "a bare asset suspend covers every contract for that underlying, including ones that sync later" do
      described_class.enable!("ET-28AUG26-CDE", reason: "test fixture")
      described_class.suspend!("ETH", reason: "negative EV — CFO 2026-07-21")

      expect(described_class.suspended?("ET-28AUG26-CDE")).to be true
      # A contract month that did not exist at suspension time:
      described_class.enable!("ET-30OCT26-CDE", reason: "rolled in")
      expect(described_class.suspended?("ET-30OCT26-CDE")).to be true
      # The spot-style eval symbol resolves to the same asset:
      expect(described_class.suspended?("ETH-USD")).to be true
    end

    it "asset suspension names the asset decision in block_reason" do
      described_class.suspend!("ETH", reason: "negative EV")

      expect(described_class.block_reason("ET-30OCT26-CDE"))
        .to include("negative EV").and include("resume ETH")
    end

    it "resuming the bare asset lifts the asset-level block" do
      described_class.suspend!("ETH", reason: "negative EV")
      described_class.resume!("ETH")
      described_class.enable!("ET-28AUG26-CDE", reason: "back on")

      expect(described_class.suspended?("ET-28AUG26-CDE")).to be false
    end

    it "resuming one contract does NOT lift the asset-level block" do
      described_class.suspend!("ETH", reason: "negative EV")
      described_class.resume!("ET-28AUG26-CDE")

      expect(described_class.suspended?("ET-28AUG26-CDE")).to be true
    end

    it "does not block other assets" do
      described_class.suspend!("ETH", reason: "negative EV")
      described_class.enable!("BIT-29AUG25-CDE", reason: "test fixture")

      expect(described_class.suspended?("BIT-29AUG25-CDE")).to be false
    end

    it "asset suspensions are listed separately for operator status" do
      described_class.suspend!("ETH", reason: "negative EV")
      described_class.suspend!("ET-31JUL26-CDE", reason: "bad roll")

      expect(described_class.asset_suspensions.keys).to eq(["ETH"])
      expect(described_class.all.keys).to include("ET-31JUL26-CDE")
      expect(described_class.all.keys).not_to include("ETH")
    end
  end

  # Issue #505 acceptance: newly ingested products are not tradeable by default
  # (fail-closed, ADR 0006 — implemented post-#503, pinned here).
  describe "fail-closed default" do
    it "a product with no recorded enablement is suspended" do
      expect(described_class.suspended?("PAU-20DEC30-CDE")).to be true
    end
  end
end
