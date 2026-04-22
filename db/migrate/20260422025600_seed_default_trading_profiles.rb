# frozen_string_literal: true

class SeedDefaultTradingProfiles < ActiveRecord::Migration[8.0]
  class TradingProfile < ApplicationRecord
    self.table_name = "trading_profiles"
  end

  def up
    profiles = [
      {
        name: "Conservative $1k",
        slug: "conservative-1k",
        signal_equity_usd: 1000,
        min_confidence: 70,
        max_signals_per_hour: 5,
        evaluation_interval_seconds: 60,
        strategy_risk_fraction: 0.01,
        strategy_tp_target: 0.004,
        strategy_sl_target: 0.003,
        active: true
      },
      {
        name: "10-Contract",
        slug: "10-contract",
        signal_equity_usd: 5000,
        min_confidence: 65,
        max_signals_per_hour: 8,
        evaluation_interval_seconds: 45,
        strategy_risk_fraction: 0.02,
        strategy_tp_target: 0.006,
        strategy_sl_target: 0.004,
        active: false
      }
    ]

    profiles.each do |attrs|
      TradingProfile.find_or_create_by!(slug: attrs[:slug]) do |profile|
        profile.assign_attributes(attrs)
      end
    end
  end

  def down
    TradingProfile.where(slug: %w[conservative-1k 10-contract]).delete_all
  end
end
