# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).
#
# Example:
#
#   ["Action", "Comedy", "Drama", "Horror"].each do |genre_name|
#     MovieGenre.find_or_create_by!(name: genre_name)
#   end

# ── TradingProfile presets ────────────────────────────────────────────────────
# Idempotent: find_or_initialize by name, update attributes to keep seeds fresh.

trading_profiles = [
  {
    name: "Conservative",
    description: "Low risk: tight position sizing, high confidence bar, conservative take-profit/stop-loss.",
    tp_target: 0.004,
    sl_target: 0.003,
    risk_fraction: 0.01,
    max_position_size: 5,
    min_position_size: 1,
    min_confidence_threshold: 75.0,
    max_signals_per_hour: 5,
    deduplication_window: 600,
    active: false
  },
  {
    name: "10-Contract",
    description: "Standard: up to 10 contracts, moderate confidence, balanced take-profit/stop-loss.",
    tp_target: 0.006,
    sl_target: 0.004,
    risk_fraction: 0.02,
    max_position_size: 15,
    min_position_size: 10,
    min_confidence_threshold: 60.0,
    max_signals_per_hour: 10,
    deduplication_window: 300,
    active: true
  }
]

trading_profiles.each do |attrs|
  profile = TradingProfile.find_or_initialize_by(name: attrs[:name])
  profile.assign_attributes(attrs)
  profile.save!
  puts "TradingProfile: #{profile.name} (#{profile.active? ? "active" : "inactive"})"
end

# Ensure exactly one active profile when seeds set multiple active
if TradingProfile.where(active: true).count > 1
  TradingProfile.where(active: true).order(:id).first.activate!
end
