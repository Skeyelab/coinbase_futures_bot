# frozen_string_literal: true

# Hard stop on analytics traffic from the test suite.
#
# Analytics::PosthogConfig already keeps posthog-rails auto-instrumentation off
# under test, but jobs/services call `PostHog.capture` directly. If a developer's
# .env holds a real POSTHOG_PROJECT_TOKEN (it does — that's how the integration
# was built), every spec run would ship events into the production PostHog
# project. That happened: spec runs showed up as real signal_generated /
# realtime_signal_tick_completed traffic.
#
# Stub it globally so no spec can reach the network. Specs that want to assert on
# analytics can still `expect(PostHog).to have_received(:capture)`.
RSpec.configure do |config|
  config.before do
    allow(PostHog).to receive(:capture)
  end
end
