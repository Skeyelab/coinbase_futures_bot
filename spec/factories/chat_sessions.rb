# frozen_string_literal: true

FactoryBot.define do
  factory :chat_session do
    session_id { SecureRandom.uuid }
    name { "Test Session" }
    active { true }
    metadata { {} }
  end
end
