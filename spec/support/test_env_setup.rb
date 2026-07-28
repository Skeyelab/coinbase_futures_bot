# frozen_string_literal: true

# Set up test environment variables that are required for tests to pass
# This ensures tests work everywhere: local development, CI/CD, and GitHub Actions
#
# These assignments run at LOAD time, not in a `before(:suite)` hook, and that
# placement is load-bearing.
#
# dotenv-rails enables `autorestore` in the test env (see dotenv/rails.rb), which
# registers `before(:suite) { Dotenv.save }` + `after { Dotenv.restore }` while
# the Rails app initializes — i.e. from `require config/environment` at the top
# of rails_helper.rb, well before this support file is loaded. `Dotenv.restore`
# is `ENV.replace(snapshot)`, a wholesale swap, so anything assigned AFTER the
# snapshot is taken is wiped after the first example and gone for the rest of
# the run.
#
# `before(:suite)` hooks run in registration order, so a hook registered here
# would land after `Dotenv.save` and its values would not survive. Assigning at
# load time puts them in ENV before `Dotenv.save` runs, so the snapshot contains
# them and every restore reinstates them. Autorestore stays on, so per-example
# ENV mutations are still cleaned up.

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

# AI Service API keys (prevent real API calls in tests)
ENV["OPENROUTER_API_KEY"] ||= "test-openrouter-key"
ENV["OPENAI_API_KEY"] ||= "test-openai-key"

puts "✅ Test environment variables configured for CI/GitHub Actions compatibility"
