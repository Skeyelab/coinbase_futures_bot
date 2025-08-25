# frozen_string_literal: true

FactoryBot.define do
  factory :position do
    product_id { 'BIT-29AUG25-CDE' }
    side { 'LONG' }
    size { 1.0 }
    entry_price { 50_000.0 }
    entry_time { Time.current }
    status { 'OPEN' }
    day_trading { true }

    trait :closed do
      status { 'CLOSED' }
      close_time { Time.current }
      pnl { 100.0 }
    end

    trait :short do
      side { 'SHORT' }
    end

    trait :old do
      entry_time { 35.days.ago }
      close_time { 34.days.ago }
      status { 'CLOSED' }
      pnl { 100.0 }
    end

    trait :yesterday do
      entry_time { 1.day.ago }
    end

    trait :approaching_closure do
      entry_time { 23.hours.ago }
    end

    trait :needing_closure do
      entry_time { 25.hours.ago }
    end
  end
end
