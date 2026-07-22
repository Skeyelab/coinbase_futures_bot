# PostHog analytics configuration with posthog-rails auto-instrumentation.
#
# posthog-rails provides:
# - Automatic exception capture for unhandled controller errors
# - ActiveJob instrumentation for background job failures
# - Rails.error integration for rescued exceptions
#
# Policy lives in Analytics::PosthogConfig (spec'd): never raise on a missing
# token, and never capture under test. PostHog.init stays unconditional so the
# bare `PostHog.capture` calls in jobs/services remain defined even when
# analytics is effectively off.
# Explicit require: initializers run before app/ autoloading is available, so
# this policy object lives in lib/ and is loaded directly.
require Rails.root.join("lib/analytics/posthog_config")

PostHog.init do |config|
  config.api_key = Analytics::PosthogConfig.token
  config.host = Analytics::PosthogConfig.host
end

if (warning = Analytics::PosthogConfig.missing_token_warning)
  Rails.logger.warn(warning)
end

if Analytics::PosthogConfig.capture_enabled?
  PostHog::Rails.configure do |config|
    config.auto_capture_exceptions = true
    config.report_rescued_exceptions = true
    config.auto_instrument_active_job = true
    config.capture_user_context = false
  end
end
