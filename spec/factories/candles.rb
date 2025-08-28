# frozen_string_literal: true

FactoryBot.define do
  factory :candle do
    symbol { "BTC-USD" }
    timeframe { "1h" }
    timestamp { Time.current.utc }
    open { 50_000.0 }
    high { 51_000.0 }
    low { 49_000.0 }
    close { 50_500.0 }
    volume { 100.0 }

    trait :recent do
      timestamp { 30.minutes.ago.utc }
    end

    trait :old do
      timestamp { 3.hours.ago.utc }
    end

    trait :one_minute do
      timeframe { "1m" }
    end

    trait :five_minute do
      timeframe { "5m" }
    end

    trait :fifteen_minute do
      timeframe { "15m" }
    end

    trait :one_hour do
      timeframe { "1h" }
    end
  end
end
