# frozen_string_literal: true

module Analytics
  # Decision seam for PostHog wiring (see config/initializers/posthog.rb).
  #
  # Two rules, both learned the hard way:
  #
  # 1. NEVER raise. The initializer used to raise when POSTHOG_PROJECT_TOKEN was
  #    blank in dev/test. That kills boot — and since CI has no token, it would
  #    fail every CI run. A missing analytics token must degrade to a warning,
  #    never take the app down.
  # 2. Capture is ALWAYS off under test. Otherwise a developer whose .env happens
  #    to hold a real token ships spec traffic into the production project.
  #
  # PostHog.init itself stays unconditional in the initializer so the bare
  # `PostHog.capture` calls scattered through jobs/services stay defined.
  module PosthogConfig
    DEFAULT_HOST = "https://us.i.posthog.com"

    module_function

    def token
      ENV["POSTHOG_PROJECT_TOKEN"].presence
    end

    def host
      ENV["POSTHOG_HOST"].presence || DEFAULT_HOST
    end

    # Should auto-capture / instrumentation be turned on?
    def capture_enabled?(rails_env: Rails.env, token: self.token)
      return false if rails_env.test?

      token.present?
    end

    # Warning string for a real env missing its token, or nil when nothing to say.
    def missing_token_warning(rails_env: Rails.env, token: self.token)
      return nil if rails_env.test?
      return nil if token.present?

      "[PostHog] POSTHOG_PROJECT_TOKEN is missing — analytics events will not be sent. " \
        "Set it (Doppler / .env) to enable capture."
    end
  end
end
