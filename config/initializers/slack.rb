# frozen_string_literal: true

# Slack integration configuration
if defined?(Slack)
  Slack.configure do |config|
    config.token = ENV['SLACK_BOT_TOKEN']
    config.logger = Rails.logger

    # Enable request/response logging in development
    config.logger.level = Logger::DEBUG if Rails.env.development?
  end
end

# Add Slack health check to Rails health monitoring
Rails.application.configure do
  config.after_initialize do
    if defined?(Rails::Health) && ENV['SLACK_ENABLED']&.downcase == 'true'
      Rails::Health.add_check :slack do
        if ENV['SLACK_BOT_TOKEN'].present?
          # Configure timeouts on the client instance
          client = Slack::Web::Client.new(
            token: ENV['SLACK_BOT_TOKEN'],
            timeout: 10,
            open_timeout: 5
          )
          response = client.auth_test
          if response['ok']
            'Slack API connection healthy'
          else
            "Slack API error: #{response['error']}"
          end
        else
          'Slack bot token not configured'
        end
      rescue StandardError => e
        "Slack connection failed: #{e.message}"
      end
    end
  end
end

# Log Slack configuration status on startup
Rails.application.configure do
  config.after_initialize do
    Rails.logger.info('[Slack] Configuration status:')
    Rails.logger.info("[Slack]   Enabled: #{ENV['SLACK_ENABLED']&.downcase == 'true'}")
    Rails.logger.info("[Slack]   Bot token configured: #{ENV['SLACK_BOT_TOKEN'].present?}")
    Rails.logger.info("[Slack]   Signing secret configured: #{ENV['SLACK_SIGNING_SECRET'].present?}")
    Rails.logger.info("[Slack]   Signals channel: #{ENV['SLACK_SIGNALS_CHANNEL'] || '#trading-signals'}")
    Rails.logger.info("[Slack]   Positions channel: #{ENV['SLACK_POSITIONS_CHANNEL'] || '#trading-positions'}")
    Rails.logger.info("[Slack]   Status channel: #{ENV['SLACK_STATUS_CHANNEL'] || '#bot-status'}")
    Rails.logger.info("[Slack]   Alerts channel: #{ENV['SLACK_ALERTS_CHANNEL'] || '#trading-alerts'}")

    authorized_users = ENV['SLACK_AUTHORIZED_USERS']&.split(',') || []
    Rails.logger.info("[Slack]   Authorized users: #{authorized_users.any? ? authorized_users.join(', ') : 'All users (no restriction)'}")
  end
end
