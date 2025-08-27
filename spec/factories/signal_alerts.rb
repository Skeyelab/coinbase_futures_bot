# frozen_string_literal: true

FactoryBot.define do
  factory :signal_alert do
    symbol { "BTC-USD" }
    side { "long" }
    signal_type { "entry" }
    strategy_name { "MultiTimeframeSignal" }
    confidence { 75 }
    entry_price { 50_000.0 }
    stop_loss { 49_000.0 }
    take_profit { 52_000.0 }
    quantity { 10 }
    timeframe { "15m" }
    alert_status { "active" }
    alert_timestamp { Time.current.utc }
    expires_at { 15.minutes.from_now.utc }
    metadata { {"test" => "metadata"} }
    strategy_data { {"ema_short" => 49_900, "ema_long" => 49_800} }

    trait :high_confidence do
      confidence { 85 }
    end

    trait :low_confidence do
      confidence { 60 }
    end

    trait :expired do
      alert_status { "expired" }
      expires_at { 1.hour.ago.utc }
    end

    trait :triggered do
      alert_status { "triggered" }
      triggered_at { Time.current.utc }
    end

    trait :short_signal do
      side { "short" }
    end

    trait :exit_signal do
      signal_type { "take_profit" }
    end

    trait :recent do
      alert_timestamp { 30.minutes.ago.utc }
    end

    trait :old do
      alert_timestamp { 2.days.ago.utc }
    end
  end
end
