# frozen_string_literal: true

# Set up test environment variables that are required for tests to pass
# This ensures tests work everywhere: local development, CI/CD, and GitHub Actions

RSpec.configure do |config|
  config.before(:suite) do
    # Set default test credentials for positions UI
    # These will be overridden by actual environment variables if set
    ENV["POSITIONS_UI_USERNAME"] ||= "admin"
    ENV["POSITIONS_UI_PASSWORD"] ||= "password123"

    # Ensure test environment
    ENV["RAILS_ENV"] = "test"

    # Slack test configuration (prevent real API calls in tests)
    ENV["SLACK_BOT_TOKEN"] ||= "xoxb-test-token-fake"
    ENV["SLACK_VERIFICATION_TOKEN"] ||= "test-verification-token-fake"
    ENV["SLACK_AUTHORIZED_USERS"] ||= "U1234567890"

    # Coinbase test configuration (prevent real API calls)
    ENV["COINBASE_API_KEY"] ||= "test-api-key"
    ENV["COINBASE_API_SECRET"] ||= "test-api-secret"

    # Database configuration (for CI environments)
    ENV["DATABASE_URL"] ||= "postgresql://postgres:postgres@localhost:5432/coinbase_futures_bot_test"

    # Sentry configuration (disable in tests)
    ENV["SENTRY_DSN"] ||= ""

    # CryptoPanic API (prevent real API calls)
    ENV["CRYPTOPANIC_API_KEY"] ||= "test-cryptopanic-key"

    puts "✅ Test environment variables configured for CI/GitHub Actions compatibility"
  end
end
