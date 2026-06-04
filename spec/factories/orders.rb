# frozen_string_literal: true

FactoryBot.define do
  factory :order do
    association :position
    contract_id { "BIT-29AUG25-CDE" }
    side { "buy" }
    order_type { "market" }
    quantity { 1.0 }
    status { "pending" }
    placed_at { Time.current }

    trait :filled do
      status { "filled" }
      fill_price { 50_100.0 }
      filled_at { Time.current }
    end

    trait :with_target do
      target_price { 50_000.0 }
    end

    trait :limit do
      order_type { "limit" }
      target_price { 50_000.0 }
    end

    trait :sell do
      side { "sell" }
    end

    trait :cancelled do
      status { "cancelled" }
    end

    trait :orphaned do
      position { nil }
    end

    trait :with_coinbase_id do
      coinbase_order_id { SecureRandom.uuid }
    end
  end
end
