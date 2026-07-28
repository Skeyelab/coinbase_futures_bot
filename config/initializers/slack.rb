# frozen_string_literal: true

# Slack integration configuration
if defined?(Slack)
  Slack.configure do |config|
    config.token = ENV["SLACK_BOT_TOKEN"]

    # Slack gets its OWN logger. It used to receive Rails.logger and then set
    # `config.logger.level = Logger::DEBUG` — the same object, so that line
    # forced the GLOBAL Rails logger to DEBUG for the whole process. The intent
    # was verbose Slack request logging; the effect was every ActiveRecord query
    # in the app.
    #
    # Measured on the always-on box: cfb-realtime emitted 17,619 lines in 60
    # seconds (~294/sec), almost all of it `Contract Load` / `TRANSACTION` /
    # `Tick Create` SQL. At ~150 bytes a line that is ~3.3 GB/day against
    # journald's 4 GB default cap — the trading loop's own logs would evict
    # themselves inside about a day, and take everything else on the box with
    # them. It also defeated RAILS_LOG_LEVEL entirely, since an initializer runs
    # after config/environments and simply overwrote it.
    #
    # A separate logger means Slack verbosity is a Slack decision again.
    slack_logger = ActiveSupport::Logger.new($stdout)
    slack_logger.level = ENV.fetch("SLACK_LOG_LEVEL", "warn").upcase.then { |l| ActiveSupport::Logger.const_get(l) }
    config.logger = slack_logger
  end
end

# Add Slack health check to Rails health monitoring
Rails.application.configure do
  config.after_initialize do
    if defined?(Rails::Health) && ENV["SLACK_ENABLED"]&.downcase == "true"
      Rails::Health.add_check :slack do
        if ENV["SLACK_BOT_TOKEN"].present?
          # Configure timeouts on the client instance
          client = Slack::Web::Client.new(
            token: ENV["SLACK_BOT_TOKEN"],
            timeout: 10,
            open_timeout: 5
          )
          response = client.auth_test
          if response["ok"]
            "Slack API connection healthy"
          else
            "Slack API error: #{response["error"]}"
          end
        else
          "Slack bot token not configured"
        end
      rescue => e
        "Slack connection failed: #{e.message}"
      end
    end
  end
end

# Log Slack configuration status on startup
Rails.application.configure do
  config.after_initialize do
    Rails.logger.info("[Slack] Configuration status:")
    Rails.logger.info("[Slack]   Enabled: #{ENV["SLACK_ENABLED"]&.downcase == "true"}")
    Rails.logger.info("[Slack]   Bot token configured: #{ENV["SLACK_BOT_TOKEN"].present?}")
    Rails.logger.info("[Slack]   Signals channel: #{ENV["SLACK_SIGNALS_CHANNEL"] || "#trading-signals"}")
    Rails.logger.info("[Slack]   Positions channel: #{ENV["SLACK_POSITIONS_CHANNEL"] || "#trading-positions"}")
    Rails.logger.info("[Slack]   Status channel: #{ENV["SLACK_STATUS_CHANNEL"] || "#bot-status"}")
    Rails.logger.info("[Slack]   Alerts channel: #{ENV["SLACK_ALERTS_CHANNEL"] || "#trading-alerts"}")
    Rails.logger.info("[Slack]   Direction: outbound only (inbound commands removed, ADR 0007)")
  end
end
