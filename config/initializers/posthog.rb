# PostHog analytics configuration with posthog-rails auto-instrumentation.
#
# posthog-rails provides:
# - Automatic exception capture for unhandled controller errors
# - ActiveJob instrumentation for background job failures
# - Rails.error integration for rescued exceptions
PostHog.init do |config|
  config.api_key = ENV.fetch("POSTHOG_PROJECT_TOKEN", nil)
  config.host = ENV.fetch("POSTHOG_HOST", "https://us.i.posthog.com")
end

if ENV["POSTHOG_PROJECT_TOKEN"].blank?
  if Rails.env.development? || Rails.env.test?
    raise "POSTHOG_PROJECT_TOKEN variable required by PostHog is missing or un-configured, this causes events to be silently missed. This error stops appearing once POSTHOG_PROJECT_TOKEN is configured"
  end
else
  PostHog::Rails.configure do |config|
    config.auto_capture_exceptions = true
    config.report_rescued_exceptions = true
    config.auto_instrument_active_job = true
    config.capture_user_context = false
  end
end
