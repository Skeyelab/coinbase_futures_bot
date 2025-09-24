# frozen_string_literal: true

FactoryBot.define do
  factory :chat_message do
    association :chat_session
    content { "Test message content" }
    message_type { "user" }
    timestamp { Time.current }
    profit_impact { "unknown" }
    relevance_score { 1.0 }
    metadata { {} }

    trait :profitable do
      profit_impact { "high" }
      relevance_score { 4.0 }
      content { "Position update: BTC-PERP long at $50000" }
    end

    trait :bot_response do
      message_type { "bot" }
      content { "Here's your trading information..." }
    end

    trait :system_message do
      message_type { "system" }
      content { "System notification" }
    end

    trait :high_relevance do
      relevance_score { 5.0 }
      profit_impact { "high" }
    end
  end
end
