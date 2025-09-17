# frozen_string_literal: true

# Global Slack mocking to prevent real API calls during tests
RSpec.configure do |config|
  config.before(:each) do
    # Disable Slack globally in tests unless specifically testing Slack functionality
    allow(ENV).to receive(:[]).with("SLACK_ENABLED").and_return("false")
    allow(ENV).to receive(:[]).with("SLACK_BOT_TOKEN").and_return(nil)

    # Mock SlackNotificationService methods to prevent real calls
    allow(SlackNotificationService).to receive(:signal_generated).and_return(true)
    allow(SlackNotificationService).to receive(:position_update).and_return(true)
    allow(SlackNotificationService).to receive(:bot_status).and_return(true)
    allow(SlackNotificationService).to receive(:alert).and_return(true)
    allow(SlackNotificationService).to receive(:pnl_update).and_return(true)
    allow(SlackNotificationService).to receive(:health_check).and_return(true)
    allow(SlackNotificationService).to receive(:market_alert).and_return(true)
    allow(SlackNotificationService).to receive(:position_type_alert).and_return(true)
    allow(SlackNotificationService).to receive(:portfolio_exposure_alert).and_return(true)
    allow(SlackNotificationService).to receive(:margin_window_transition).and_return(true)

    # Mock the Slack Web Client to prevent real API calls
    slack_client_mock = instance_double(Slack::Web::Client)
    allow(Slack::Web::Client).to receive(:new).and_return(slack_client_mock)
    allow(slack_client_mock).to receive(:chat_postMessage).and_return(true)
    allow(slack_client_mock).to receive(:auth_test).and_return({"ok" => true})
  end
end
