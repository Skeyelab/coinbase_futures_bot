# frozen_string_literal: true

require "rails_helper"

RSpec.describe TradingConfiguration, type: :service do
  let(:profile_attrs) do
    {
      name: "Test Profile",
      slug: "test-profile",
      signal_equity_usd: 5000,
      min_confidence: 75,
      max_signals_per_hour: 8,
      evaluation_interval_seconds: 45,
      strategy_risk_fraction: 0.02,
      strategy_tp_target: 0.006,
      strategy_sl_target: 0.004,
      active: true
    }
  end

  before { described_class.reset_profile_cache! }
  after { described_class.reset_profile_cache! }

  describe ".current_profile" do
    it "returns the active profile" do
      profile = TradingProfile.create!(profile_attrs)
      expect(described_class.current_profile).to eq(profile)
    end

    it "returns nil when no active profile exists" do
      expect(described_class.current_profile).to be_nil
    end

    it "memoizes the result within the same call cycle" do
      TradingProfile.create!(profile_attrs)
      expect(TradingProfile).to receive(:active).once.and_call_original
      2.times { described_class.current_profile }
    end
  end

  describe ".reset_profile_cache!" do
    it "clears the memoized profile so the next call queries the DB" do
      TradingProfile.create!(profile_attrs)
      described_class.current_profile # warm cache
      expect(TradingProfile).to receive(:active).once.and_call_original
      described_class.reset_profile_cache!
      described_class.current_profile
    end
  end

  describe "profile value precedence over env vars" do
    before { TradingProfile.create!(profile_attrs) }

    it "returns profile signal_equity_usd over env default" do
      expect(described_class.signal_equity_usd).to eq(5000.0)
    end

    it "returns profile min_confidence over env default" do
      expect(described_class.min_confidence).to eq(75.0)
    end

    it "returns profile max_signals_per_hour over env default" do
      expect(described_class.max_signals_per_hour).to eq(8)
    end

    it "returns profile evaluation_interval_seconds over env default" do
      expect(described_class.evaluation_interval_seconds).to eq(45)
    end

    it "returns profile strategy_risk_fraction over env default" do
      expect(described_class.strategy_risk_fraction).to be_within(0.0001).of(0.02)
    end

    it "returns profile strategy_tp_target over env default" do
      expect(described_class.strategy_tp_target).to be_within(0.0001).of(0.006)
    end

    it "returns profile strategy_sl_target over env default" do
      expect(described_class.strategy_sl_target).to be_within(0.0001).of(0.004)
    end
  end

  describe "env var fallback when no active profile" do
    it "falls back to SIGNAL_EQUITY_USD env var" do
      ClimateControl.modify("SIGNAL_EQUITY_USD" => "25000") do
        described_class.reset_profile_cache!
        expect(described_class.signal_equity_usd).to eq(25_000.0)
      end
    end

    it "falls back to REALTIME_SIGNAL_MIN_CONFIDENCE env var" do
      ClimateControl.modify("REALTIME_SIGNAL_MIN_CONFIDENCE" => "80") do
        described_class.reset_profile_cache!
        expect(described_class.min_confidence).to eq(80.0)
      end
    end

    it "falls back to REALTIME_SIGNAL_MAX_PER_HOUR env var" do
      ClimateControl.modify("REALTIME_SIGNAL_MAX_PER_HOUR" => "20") do
        described_class.reset_profile_cache!
        expect(described_class.max_signals_per_hour).to eq(20)
      end
    end

    it "falls back to hard-coded defaults when env vars are absent" do
      described_class.reset_profile_cache!
      expect(described_class.signal_equity_usd).to eq(10_000.0)
      expect(described_class.min_confidence).to eq(60.0)
      expect(described_class.max_signals_per_hour).to eq(10)
      expect(described_class.evaluation_interval_seconds).to eq(30)
      expect(described_class.strategy_risk_fraction).to be_within(0.0001).of(0.01)
      expect(described_class.strategy_tp_target).to be_within(0.0001).of(0.006)
      expect(described_class.strategy_sl_target).to be_within(0.0001).of(0.004)
    end
  end

  describe "type coercion and invalid env var handling" do
    it "falls back to default when SIGNAL_EQUITY_USD is non-numeric" do
      ClimateControl.modify("SIGNAL_EQUITY_USD" => "not_a_number") do
        described_class.reset_profile_cache!
        expect(described_class.signal_equity_usd).to eq(10_000.0)
      end
    end

    it "falls back to default when REALTIME_SIGNAL_MAX_PER_HOUR is non-integer" do
      ClimateControl.modify("REALTIME_SIGNAL_MAX_PER_HOUR" => "bad_value") do
        described_class.reset_profile_cache!
        expect(described_class.max_signals_per_hour).to eq(10)
      end
    end
  end

  describe "switching active profile" do
    it "reflects the newly activated profile after cache reset" do
      first = TradingProfile.create!(profile_attrs)
      second = TradingProfile.create!(
        profile_attrs.merge(name: "Second", slug: "second", signal_equity_usd: 9999, active: false)
      )

      expect(described_class.signal_equity_usd).to eq(5000.0)

      second.activate!

      expect(described_class.signal_equity_usd).to eq(9999.0)
      expect(described_class.current_profile).to eq(second.reload)
      expect(first.reload).not_to be_active
    end
  end
end
