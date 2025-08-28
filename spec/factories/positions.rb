# frozen_string_literal: true

FactoryBot.define do
  factory :position do
    product_id { "BIT-29AUG25-CDE" }
    side { "LONG" }
    size { 1.0 }
    entry_price { 50_000.0 }
    entry_time { Time.current }
    status { "OPEN" }
    day_trading { true }

    trait :closed do
      status { "CLOSED" }
      close_time { Time.current }
      pnl { 100.0 }
    end

    trait :short do
      side { "SHORT" }
    end

    trait :old do
      entry_time { 35.days.ago }
      close_time { 34.days.ago }
      status { "CLOSED" }
      pnl { 100.0 }
    end

    trait :yesterday do
      entry_time { 30.hours.ago } # Within the 24-48 hour range for opened_yesterday scope
      status { "OPEN" }
    end

    trait :approaching_closure do
      entry_time { 23.5.hours.ago } # Older than 23 hours ago for approaching_closure scope
    end

    trait :needing_closure do
      entry_time { 25.hours.ago }
    end

    trait :with_tp_sl do
      take_profit { 51000.0 }
      stop_loss { 49000.0 }
    end

    trait :triggered_tp do
      take_profit { 49000.0 } # Below entry price for LONG - triggers TP
      stop_loss { 48000.0 }
    end

    trait :triggered_sl do
      take_profit { 52000.0 }
      stop_loss { 51000.0 } # Above entry price for LONG - triggers SL
    end

    trait :eth do
      product_id { "ET-29AUG25-CDE" }
      entry_price { 3000.0 }
    end

    trait :recent do
      entry_time { 12.hours.ago }
    end
  end
end
