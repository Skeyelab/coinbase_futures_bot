# frozen_string_literal: true

FactoryBot.define do
  factory :trading_pair do
    # Dynamic contract ID generation to reduce hardcoded values
    transient do
      contract_month { Date.current }
      asset { "BTC" }
    end

    product_id do
      # Generate contract ID dynamically based on asset and month
      prefix = MarketData::FuturesContractManager::ASSET_MAPPING[asset.upcase]
      if prefix
        # Find last Friday of the month
        last_day = contract_month.end_of_month
        expiration_date = last_day
        until expiration_date.friday?
          expiration_date -= 1.day
          break if expiration_date < contract_month.beginning_of_month
        end
        date_str = expiration_date.strftime("%d%b%y").upcase
        "#{prefix}-#{date_str}-CDE"
      else
        "BIT-#{contract_month.strftime("%d%b%y").upcase}-CDE" # fallback
      end
    end

    base_currency { asset.upcase }
    quote_currency { "USD" }
    status { "online" }
    min_size { 0.0001 }
    price_increment { 0.01 }
    size_increment { 0.00001 }
    enabled { true }
    contract_type { "CDE" }

    # Calculate expiration date from contract month
    expiration_date do
      last_day = contract_month.end_of_month
      expiration_date = last_day
      until expiration_date.friday?
        expiration_date -= 1.day
        break if expiration_date < contract_month.beginning_of_month
      end
      expiration_date
    end

    trait :disabled do
      enabled { false }
    end

    trait :expired do
      contract_month { Date.current - 1.month }
    end

    trait :ethereum do
      asset { "ETH" }
    end

    trait :current_month do
      contract_month { Date.current }
    end

    trait :upcoming_month do
      contract_month { Date.current.next_month }
    end

    # Legacy support - creates a contract for a specific date (use sparingly)
    trait :for_date do
      transient do
        specific_date { Date.current }
      end

      contract_month { specific_date }
    end
  end
end
