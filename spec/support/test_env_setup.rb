# frozen_string_literal: true

# Set up test environment variables that are required for tests to pass
# This ensures tests work even when .env file is not present

RSpec.configure do |config|
  config.before(:suite) do
    # Set default test credentials for positions UI
    ENV["POSITIONS_UI_USERNAME"] ||= "admin"
    ENV["POSITIONS_UI_PASSWORD"] ||= "password123"
    
    # Set other test environment variables as needed
    ENV["RAILS_ENV"] = "test"
    
    # Slack test configuration (if needed)
    ENV["SLACK_BOT_TOKEN"] ||= "xoxb-test-token"
    ENV["SLACK_VERIFICATION_TOKEN"] ||= "test-verification-token"
    ENV["SLACK_AUTHORIZED_USERS"] ||= "U1234567890"
  end
end