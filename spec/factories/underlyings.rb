# frozen_string_literal: true

FactoryBot.define do
  factory :underlying do
    sequence(:symbol) { |n| ["BTC", "ETH", "OIL"][n % 3] + ((n < 3) ? "" : n.to_s) }
    name { {"BTC" => "Bitcoin", "ETH" => "Ethereum", "OIL" => "Crude Oil"}[symbol.sub(/\d+$/, "")] || symbol }
    asset_class { symbol.start_with?("OIL") ? "commodity" : "crypto" }

    trait :btc do
      symbol { "BTC" }
      name { "Bitcoin" }
      asset_class { "crypto" }
    end

    trait :eth do
      symbol { "ETH" }
      name { "Ethereum" }
      asset_class { "crypto" }
    end

    trait :oil do
      symbol { "OIL" }
      name { "Crude Oil" }
      asset_class { "commodity" }
    end
  end
end
