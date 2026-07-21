# frozen_string_literal: true

require "rails_helper"

RSpec.describe TradingProfile do
  # ── Validations ───────────────────────────────────────────────────────────────

  describe "validations" do
    subject(:profile) { build(:trading_profile) }

    it "is valid with default factory attributes" do
      expect(profile).to be_valid
    end

    it "requires a name" do
      profile.name = nil
      expect(profile).not_to be_valid
      expect(profile.errors[:name]).to be_present
    end

    it "enforces unique name case-insensitively" do
      create(:trading_profile, name: "Aggressive")
      dup = build(:trading_profile, name: "aggressive")
      expect(dup).not_to be_valid
    end

    it "requires tp_target > 0" do
      profile.tp_target = 0
      expect(profile).not_to be_valid
    end

    it "requires tp_target < 1" do
      profile.tp_target = 1.5
      expect(profile).not_to be_valid
    end

    it "requires sl_target > 0 and < 1" do
      profile.sl_target = -0.001
      expect(profile).not_to be_valid
    end

    it "requires risk_fraction > 0 and < 1" do
      profile.risk_fraction = 0
      expect(profile).not_to be_valid
    end

    it "requires min_confidence_threshold between 0 and 100" do
      profile.min_confidence_threshold = 110
      expect(profile).not_to be_valid
    end

    it "requires max_position_size > 0" do
      profile.max_position_size = 0
      expect(profile).not_to be_valid
    end

    it "requires min_position_size <= max_position_size" do
      profile.min_position_size = 20
      profile.max_position_size = 10
      expect(profile).not_to be_valid
      expect(profile.errors[:min_position_size]).to be_present
    end

    it "allows min_position_size == max_position_size" do
      profile.min_position_size = 10
      profile.max_position_size = 10
      expect(profile).to be_valid
    end

    it "requires max_signals_per_hour > 0" do
      profile.max_signals_per_hour = 0
      expect(profile).not_to be_valid
    end

    it "requires deduplication_window >= 0" do
      profile.deduplication_window = -1
      expect(profile).not_to be_valid
    end
  end

  # ── .active_profile ───────────────────────────────────────────────────────────

  describe ".active_profile" do
    it "returns nil when no profile is active" do
      create(:trading_profile)
      expect(described_class.active_profile).to be_nil
    end

    it "returns the active profile" do
      profile = create(:trading_profile, :active)
      expect(described_class.active_profile).to eq(profile)
    end
  end

  # ── Per-symbol calibration profiles (issue #299) ─────────────────────────────

  describe "per-symbol profiles" do
    it ".effective(symbol:) prefers the symbol's active profile over the global one" do
      global = create(:trading_profile, :active, name: "global")
      btc = create(:trading_profile, name: "btc-cal", symbol: "BTC-USD", active: true)

      expect(described_class.effective(symbol: "BTC-USD")).to eq(btc)
      expect(described_class.effective(symbol: "ETH-USD")).to eq(global)
      expect(described_class.effective).to eq(global)
    end

    it ".effective(symbol:) falls back to env defaults when nothing is active" do
      expect(described_class.effective(symbol: "BTC-USD")).to be_readonly
    end

    it "activate! only deactivates profiles for the same symbol" do
      global = create(:trading_profile, :active, name: "global")
      btc_v1 = create(:trading_profile, name: "btc-v1", symbol: "BTC-USD", active: true)
      btc_v2 = create(:trading_profile, name: "btc-v2", symbol: "BTC-USD")

      btc_v2.activate!

      expect(btc_v1.reload.active).to be false
      expect(btc_v2.reload.active).to be true
      expect(global.reload.active).to be true
    end

    it "enforces at most one active profile per symbol at the DB level" do
      create(:trading_profile, name: "btc-v1", symbol: "BTC-USD", active: true)

      expect do
        create(:trading_profile, name: "btc-v2", symbol: "BTC-USD", active: true)
      end.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  # ── .effective ────────────────────────────────────────────────────────────────

  describe ".effective" do
    it "returns the active profile when one exists" do
      profile = create(:trading_profile, :active)
      expect(described_class.effective).to eq(profile)
    end

    it "returns a default profile struct when no profile is active" do
      result = described_class.effective
      expect(result).to be_a(described_class)
      expect(result).not_to be_persisted
      expect(result.name).to eq("default (env)")
    end

    it "default profile is read-only to prevent accidental persistence" do
      result = described_class.effective
      expect { result.save! }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end

    it "default profile reads STRATEGY_TP_TARGET / STRATEGY_SL_TARGET / STRATEGY_RISK_FRACTION env vars" do
      ClimateControl.modify(STRATEGY_TP_TARGET: "0.009", STRATEGY_SL_TARGET: "0.005", STRATEGY_RISK_FRACTION: "0.03") do
        result = described_class.default_profile
        expect(result.tp_target).to eq(0.009)
        expect(result.sl_target).to eq(0.005)
        expect(result.risk_fraction).to eq(0.03)
      end
    end

    it "default profile has sensible values" do
      result = described_class.effective
      expect(result.tp_target).to be > 0
      expect(result.sl_target).to be > 0
      expect(result.max_position_size).to be > 0
      expect(result.min_confidence_threshold).to be_between(0, 100)
    end
  end

  # ── #activate! ────────────────────────────────────────────────────────────────

  describe "#activate!" do
    it "marks the profile as active" do
      profile = create(:trading_profile)
      profile.activate!
      expect(profile.reload.active).to be true
    end

    it "deactivates the previously active profile" do
      old = create(:trading_profile, :active)
      new_profile = create(:trading_profile)
      new_profile.activate!
      expect(old.reload.active).to be false
      expect(new_profile.reload.active).to be true
    end

    it "is idempotent — activating already-active profile is a no-op" do
      profile = create(:trading_profile, :active)
      profile.activate!
      expect(described_class.where(active: true).count).to eq(1)
    end

    it "ensures exactly one active profile" do
      profiles = create_list(:trading_profile, 3)
      profiles.each(&:activate!)
      expect(described_class.where(active: true).count).to eq(1)
    end

    it "returns self" do
      profile = create(:trading_profile)
      expect(profile.activate!).to eq(profile)
    end
  end

  # ── #deactivate! ──────────────────────────────────────────────────────────────

  describe "#deactivate!" do
    it "marks the profile as inactive" do
      profile = create(:trading_profile, :active)
      profile.deactivate!
      expect(profile.reload.active).to be false
    end

    it "returns self" do
      profile = create(:trading_profile, :active)
      expect(profile.deactivate!).to eq(profile)
    end
  end

  # ── preset traits ────────────────────────────────────────────────────────────

  describe "factory traits" do
    it "conservative trait has lower risk settings" do
      profile = build(:trading_profile, :conservative)
      expect(profile.tp_target).to be < 0.006
      expect(profile.max_position_size).to be <= 5
      expect(profile.min_confidence_threshold).to be >= 70
    end

    it "ten_contract trait has higher sizing" do
      profile = build(:trading_profile, :ten_contract)
      expect(profile.min_position_size).to be >= 10
    end
  end
end
