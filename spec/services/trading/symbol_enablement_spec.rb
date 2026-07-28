# frozen_string_literal: true

require "rails_helper"

# ADR 0006 decision 4: suspension fails closed. A symbol with no recorded
# enablement is treated as suspended.
#
# Before this, Trading::SymbolSuspension started EMPTY and `suspended?` was a
# membership test against that empty store, so every symbol the ingestion
# pipeline produced was tradeable the moment it appeared. contract.rb's claim
# that "PAU stays SymbolSuspension-suspended" was aspirational: nothing made it
# true. Adding one line to PREFIX_TO_BASE_CURRENCY was enough to put a new
# instrument on the order path.
RSpec.describe Trading::SymbolSuspension, "fail-closed enablement", type: :service, universe_scope: true do
  it "treats a symbol with no recorded enablement as suspended" do
    expect(described_class.suspended?("PAU-20DEC30-CDE")).to be true
    expect(described_class.enabled?("PAU-20DEC30-CDE")).to be false
  end

  it "names the exact command an operator must run to unblock the symbol" do
    expect(described_class.block_reason("PAU-20DEC30-CDE"))
      .to include("bin/futuresbot resume PAU-20DEC30-CDE")
  end

  it "permits a symbol only after an explicit enablement is recorded" do
    described_class.enable!("BIP-20DEC30-CDE", reason: "walk-forward passed")

    expect(described_class.suspended?("BIP-20DEC30-CDE")).to be false
    expect(described_class.enabled?("BIP-20DEC30-CDE")).to be true
    expect(described_class.suspended?("XPP-20DEC30-CDE")).to be true
  end

  it "records who/why/when for an enablement, listable via .enablements" do
    described_class.enable!("BIP-20DEC30-CDE", reason: "walk-forward passed")

    entry = described_class.enablements["BIP-20DEC30-CDE"]
    expect(entry["reason"]).to eq("walk-forward passed")
    expect(Time.parse(entry["enabled_at"])).to be_within(5).of(Time.current)
  end

  it "revokes enablement when a symbol is suspended, so resume is deliberate" do
    described_class.enable!("BIP-20DEC30-CDE", reason: "walk-forward passed")
    described_class.suspend!("BIP-20DEC30-CDE", reason: "cost bleed")

    expect(described_class.suspended?("BIP-20DEC30-CDE")).to be true
    expect(described_class.enabled?("BIP-20DEC30-CDE")).to be false
    expect(described_class.block_reason("BIP-20DEC30-CDE")).to include("cost bleed")
  end

  it "keeps an explicit suspension authoritative over a stale enablement record" do
    described_class.suspend!("BIP-20DEC30-CDE", reason: "cost bleed")
    described_class.update_enablements { |e| e["BIP-20DEC30-CDE"] = {"reason" => "stale"} }

    expect(described_class.suspended?("BIP-20DEC30-CDE")).to be true
  end

  it "is durable across processes (BotRuntimeStat-backed)" do
    described_class.enable!("BIP-20DEC30-CDE", reason: "x")

    expect(BotRuntimeStat.find_by(key: described_class::ENABLEMENT_KEY)).to be_present
    expect(Trading::SymbolSuspension.enabled?("BIP-20DEC30-CDE")).to be true
  end

  describe "LIVE_INSTRUMENTS seed" do
    # A deploy must be able to declare its live list without a human running a
    # CLI verb against a fresh database, or the fail-closed default becomes an
    # outage that only a console can end.
    it "treats symbols named in LIVE_INSTRUMENTS as enabled" do
      stub_const("ENV", ENV.to_hash.merge("LIVE_INSTRUMENTS" => "BIP-20DEC30-CDE, NOL-30SEP26-CDE"))

      expect(described_class.suspended?("BIP-20DEC30-CDE")).to be false
      expect(described_class.suspended?("NOL-30SEP26-CDE")).to be false
      expect(described_class.suspended?("PAU-20DEC30-CDE")).to be true
    end

    it "still lets an explicit suspension override the seed" do
      stub_const("ENV", ENV.to_hash.merge("LIVE_INSTRUMENTS" => "BIP-20DEC30-CDE"))
      described_class.suspend!("BIP-20DEC30-CDE", reason: "cost bleed")

      expect(described_class.suspended?("BIP-20DEC30-CDE")).to be true
    end
  end

  describe ".live_symbols" do
    it "lists every symbol currently permitted to trade" do
      stub_const("ENV", ENV.to_hash.merge("LIVE_INSTRUMENTS" => "NOL-30SEP26-CDE"))
      described_class.enable!("BIP-20DEC30-CDE", reason: "x")
      described_class.enable!("XPP-20DEC30-CDE", reason: "x")
      described_class.suspend!("XPP-20DEC30-CDE", reason: "cost bleed")

      expect(described_class.live_symbols).to contain_exactly("BIP-20DEC30-CDE", "NOL-30SEP26-CDE")
    end
  end
end
