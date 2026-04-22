# frozen_string_literal: true

require "rails_helper"

RSpec.describe TradingProfile, type: :model do
  it "validates required attributes" do
    profile = described_class.new
    expect(profile).not_to be_valid
    expect(profile.errors[:name]).to be_present
    expect(profile.errors[:slug]).to be_present
  end

  it "normalizes slug" do
    profile = described_class.create!(
      name: "Ten Contract Profile",
      slug: "Ten Contract Profile",
      signal_equity_usd: 5000,
      min_confidence: 65,
      max_signals_per_hour: 8,
      evaluation_interval_seconds: 45,
      strategy_risk_fraction: 0.02,
      strategy_tp_target: 0.006,
      strategy_sl_target: 0.004
    )

    expect(profile.slug).to eq("ten-contract-profile")
  end

  it "activates one profile at a time" do
    first = described_class.create!(
      name: "First",
      slug: "first",
      signal_equity_usd: 1000,
      min_confidence: 70,
      max_signals_per_hour: 5,
      evaluation_interval_seconds: 60,
      strategy_risk_fraction: 0.01,
      strategy_tp_target: 0.004,
      strategy_sl_target: 0.003,
      active: true
    )
    second = described_class.create!(
      name: "Second",
      slug: "second",
      signal_equity_usd: 5000,
      min_confidence: 65,
      max_signals_per_hour: 8,
      evaluation_interval_seconds: 45,
      strategy_risk_fraction: 0.02,
      strategy_tp_target: 0.006,
      strategy_sl_target: 0.004,
      active: false
    )

    second.activate!

    expect(second.reload).to be_active
    expect(first.reload).not_to be_active
  end
end
