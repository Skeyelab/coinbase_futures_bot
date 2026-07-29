# frozen_string_literal: true

require "rails_helper"

# Transition-based Slack alerting (issue #561, third instance of the
# alert-a-state-forever shape from #548/#557): the hourly job must post on
# health-state CHANGES plus at most one daily reminder while degraded, not
# re-announce a persistent warning every hour.
RSpec.describe HealthCheckJob, "transition-based alerting", type: :job do
  let(:job) { described_class.new }

  before do
    allow(SlackNotificationService).to receive(:health_check)
    allow(SlackNotificationService).to receive(:alert)
    allow(Rails.cache).to receive(:write)
  end

  def stub_health(overall)
    allow(job).to receive(:gather_health_data).and_return({overall_health: overall})
  end

  def seed_state(state, notified_at:)
    BotRuntimeStat.upsert_value!(
      key: described_class::HEALTH_ALERT_STATE_KEY,
      value: {"state" => state, "notified_at" => notified_at.utc.iso8601}
    )
  end

  def stored_state
    BotRuntimeStat.find_by(key: described_class::HEALTH_ALERT_STATE_KEY)&.value
  end

  it "posts when health degrades from healthy to warning" do
    seed_state("healthy", notified_at: 1.hour.ago)
    stub_health("warning")

    job.perform

    expect(SlackNotificationService).to have_received(:health_check).once
    expect(stored_state["state"]).to eq("warning")
  end

  it "posts when a warning escalates to unhealthy" do
    seed_state("warning", notified_at: 1.hour.ago)
    stub_health("unhealthy")

    job.perform

    expect(SlackNotificationService).to have_received(:health_check).once
  end

  it "posts on the first-ever degraded run (no stored state)" do
    stub_health("warning")

    job.perform

    expect(SlackNotificationService).to have_received(:health_check).once
  end

  it "stays silent on a steady-state warning notified within the last 24h" do
    seed_state("warning", notified_at: 2.hours.ago)
    stub_health("warning")

    job.perform

    expect(SlackNotificationService).not_to have_received(:health_check)
  end

  it "stays silent while healthy" do
    seed_state("healthy", notified_at: 3.days.ago)
    stub_health("healthy")

    job.perform

    expect(SlackNotificationService).not_to have_received(:health_check)
  end

  it "stays silent when healthy with no stored state (first boot)" do
    stub_health("healthy")

    job.perform

    expect(SlackNotificationService).not_to have_received(:health_check)
  end

  it "sends at most one daily reminder while degraded" do
    seed_state("warning", notified_at: 25.hours.ago)
    stub_health("warning")

    job.perform

    expect(SlackNotificationService).to have_received(:health_check).once

    # The reminder refreshed notified_at, so the next hourly run is silent.
    job2 = described_class.new
    allow(job2).to receive(:gather_health_data).and_return({overall_health: "warning"})
    job2.perform

    expect(SlackNotificationService).to have_received(:health_check).once
  end

  it "posts once on recovery to healthy, then goes silent" do
    seed_state("warning", notified_at: 2.hours.ago)
    stub_health("healthy")

    job.perform

    expect(SlackNotificationService).to have_received(:health_check).once
    expect(stored_state["state"]).to eq("healthy")

    job2 = described_class.new
    allow(job2).to receive(:gather_health_data).and_return({overall_health: "healthy"})
    job2.perform

    expect(SlackNotificationService).to have_received(:health_check).once
  end

  it "always posts on the explicit operator-requested path even in steady state" do
    seed_state("warning", notified_at: 2.hours.ago)
    stub_health("warning")

    job.perform(send_slack_notification: true)

    expect(SlackNotificationService).to have_received(:health_check).once
  end
end
