# frozen_string_literal: true

FactoryBot.define do
  factory :trading_profile do
    sequence(:name) { |n| "Profile #{n}" }
    description { "Test trading profile" }
    tp_target { 0.006 }
    sl_target { 0.004 }
    risk_fraction { 0.02 }
    max_position_size { 15 }
    min_position_size { 5 }
    min_confidence_threshold { 60.0 }
    max_signals_per_hour { 10 }
    deduplication_window { 300 }
    active { false }

    trait :active do
      active { true }
    end

    trait :conservative do
      name { "Conservative" }
      tp_target { 0.004 }
      sl_target { 0.003 }
      risk_fraction { 0.01 }
      max_position_size { 5 }
      min_position_size { 1 }
      min_confidence_threshold { 75.0 }
      max_signals_per_hour { 5 }
    end

    trait :aggressive do
      name { "10-Contract" }
      tp_target { 0.008 }
      sl_target { 0.005 }
      risk_fraction { 0.03 }
      max_position_size { 15 }
      min_position_size { 10 }
      min_confidence_threshold { 55.0 }
      max_signals_per_hour { 15 }
    end
  end
end
