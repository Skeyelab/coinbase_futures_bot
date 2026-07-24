# frozen_string_literal: true

require "rails_helper"

# Issue #401: live MaxDrawdown evaluation. Live equity history isn't persisted, so
# the monitor keeps a durable running peak (BotRuntimeStat) — drawdown from that
# peak is the equity-curve drawdown. On a breach it writes the global halt and
# fires a Slack warning.
RSpec.describe Trading::Protections::MaxDrawdownMonitor, type: :service do
  around do |ex|
    orig = Rails.application.config.real_time_signals
    Rails.application.config.real_time_signals = orig.merge(
      protections: orig[:protections].merge(max_drawdown: {ceiling: 0.10, lookback_seconds: 86_400, lock_ttl_seconds: 1800})
    )
    ex.run
    Rails.application.config.real_time_signals = orig
    Trading::ProtectionLock.clear!
  end

  before { allow(SlackNotificationService).to receive(:alert) }

  it "tracks the running peak and does not halt on a new high or shallow dip" do
    described_class.evaluate(current_equity: 10_000.0)
    described_class.evaluate(current_equity: 11_000.0) # new high
    described_class.evaluate(current_equity: 10_500.0) # ~4.5% off peak < 10%

    expect(Trading::Protections.blocked?(symbol: "ANY", side: "long")).to be false
  end

  it "halts globally and alerts when drawdown from the peak exceeds the ceiling" do
    described_class.evaluate(current_equity: 10_000.0) # sets peak 10k
    expect(SlackNotificationService).to receive(:alert).with("warning", /drawdown/i, anything)

    described_class.evaluate(current_equity: 8_500.0) # 15% off peak

    expect(Trading::Protections.blocked?(symbol: "ANY", side: "long")).to be true
    expect(Trading::Protections.blocked?(symbol: "OTHER", side: "short")).to be true
  end

  it "is inert when disabled" do
    Rails.application.config.real_time_signals =
      Rails.application.config.real_time_signals.merge(
        protections: Rails.application.config.real_time_signals[:protections].merge(max_drawdown: {ceiling: 0})
      )
    described_class.evaluate(current_equity: 10_000.0)
    described_class.evaluate(current_equity: 1.0)
    expect(Trading::Protections.blocked?(symbol: "ANY", side: "long")).to be false
  end
end
