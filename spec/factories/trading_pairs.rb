# frozen_string_literal: true

FactoryBot.define do
  factory :trading_pair do
    product_id { "BTC-29AUG25-CDE" }
    base_currency { "BTC" }
    quote_currency { "USD" }
    status { "online" }
    min_size { 0.0001 }
    price_increment { 0.01 }
    size_increment { 0.00001 }
    enabled { true }
    contract_type { "futures" }
    expiration_date { Date.current.next_month.end_of_month }

    trait :disabled do
      enabled { false }
    end

    trait :expired do
      expiration_date { Date.current - 1.day }
    end

    trait :ethereum do
      product_id { "ET-29AUG25-CDE" }
      base_currency { "ETH" }
    end
  end
end
