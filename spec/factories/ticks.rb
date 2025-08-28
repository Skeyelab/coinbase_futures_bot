# frozen_string_literal: true

FactoryBot.define do
  factory :tick do
    product_id { 'BTC-USD' }
    price { 50_000.0 }
    observed_at { Time.current.utc }

    trait :recent do
      observed_at { 1.minute.ago.utc }
    end

    trait :old do
      observed_at { 10.minutes.ago.utc }
    end

    trait :expired do
      observed_at { 10.minutes.ago.utc }
    end
  end
end
