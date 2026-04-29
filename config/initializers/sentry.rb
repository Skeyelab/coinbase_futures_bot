# frozen_string_literal: true

Sentry.init do |config|
  config.dsn = ENV["SENTRY_DSN"]
  config.environment = Rails.env
  config.breadcrumbs_logger = [:active_support_logger, :http_logger]

  # Performance monitoring configuration
  config.traces_sample_rate = (ENV["SENTRY_TRACES_SAMPLE_RATE"] || 0.1).to_f
  config.profiles_sample_rate = (ENV["SENTRY_PROFILES_SAMPLE_RATE"] || 0.1).to_f

  # Enable performance monitoring for background jobs.
  # Some Sentry versions don't expose all tracing subscriber constants.
  config.rails.report_rescued_exceptions = true
  config.rails.tracing_subscribers = [
    "Sentry::Rails::Tracing::ActiveRecordSubscriber",
    "Sentry::Rails::Tracing::ActionControllerSubscriber"
  ].filter_map do |subscriber_name|
    subscriber_name.safe_constantize
  end

  # Sanitize known secrets and sensitive data
  config.inspect_exception_causes_for_exclusion = true
  config.send_default_pii = false

  # Filter sensitive parameters
  config.excluded_exceptions += [
    "ActiveJob::DeserializationError",
    "ActionController::RoutingError"
  ]

  # Custom error grouping for better organization
  config.before_send = lambda do |event, hint|
    # Add custom tags for trading bot context
    if event.transaction
      case event.transaction
      when /Job/
        event.tags[:component] = "background_job"
      when /Controller/
        event.tags[:component] = "api_controller"
      when /Service/
        event.tags[:component] = "service"
      end
    end

    # Add trading context if available
    if defined?(Rails) && Rails.respond_to?(:logger)
      event.tags[:trading_mode] = (ENV["PAPER_TRADING_MODE"] == "true") ? "paper" : "live"
      event.tags[:sentiment_enabled] = (ENV["SENTIMENT_ENABLE"] == "true") ? "enabled" : "disabled"
    end

    event
  end

  # Set release information
  config.release = ENV["APP_VERSION"] || "unknown"

  # Configure sample rates for different environments
  case Rails.env
  when "production"
    config.traces_sample_rate = (ENV["SENTRY_TRACES_SAMPLE_RATE"] || 0.1).to_f
    config.profiles_sample_rate = (ENV["SENTRY_PROFILES_SAMPLE_RATE"] || 0.1).to_f
  when "staging"
    config.traces_sample_rate = (ENV["SENTRY_TRACES_SAMPLE_RATE"] || 0.5).to_f
    config.profiles_sample_rate = (ENV["SENTRY_PROFILES_SAMPLE_RATE"] || 0.5).to_f
  when "development"
    config.traces_sample_rate = (ENV["SENTRY_TRACES_SAMPLE_RATE"] || 1.0).to_f
    config.profiles_sample_rate = (ENV["SENTRY_PROFILES_SAMPLE_RATE"] || 1.0).to_f
  end
end
