# frozen_string_literal: true

# Test-specific Sentry configuration
# This disables Sentry tracking in test environment for better performance
# while still allowing us to test Sentry integration in specific tests

if Rails.env.test?
  # Disable Sentry entirely in test environment
  Sentry.configuration.dsn = nil

  # Disable Sentry tracking for models to improve test performance
  # We can still test Sentry integration by explicitly enabling it in specific tests
  module SentryTrackable
    def self.included(base)
      # Skip including Sentry tracking in test environment
      # Tests can still verify Sentry integration by mocking or enabling it explicitly
    end
  end
end
