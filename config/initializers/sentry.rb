# frozen_string_literal: true

Sentry.init do |config|
  config.dsn = ENV["SENTRY_DSN"]
  config.environment = Rails.env
  config.breadcrumbs_logger = [:active_support_logger, :http_logger]

  # Disable performance tracing unless explicitly enabled
  config.traces_sample_rate = (ENV["SENTRY_TRACES_SAMPLE_RATE"] || 0).to_f

  # Sanitize known secrets
  config.inspect_exception_causes_for_exclusion = true
  config.send_default_pii = false
end
