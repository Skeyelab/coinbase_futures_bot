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

  # The live monitor runs every ~30s. Before this, a single stuck breach sent a
  # Slack warning on every cycle — ten identical alerts in five minutes,
  # observed 2026-07-28 after an equity reset invalidated the peak watermark.
  # A halt is a state; the alert belongs to the transition into it.
  it "alerts once for an ongoing breach, not once per evaluation cycle" do
    described_class.evaluate(current_equity: 10_000.0) # establish the peak
    described_class.evaluate(current_equity: 8_000.0)  # breach -> halt + alert
    described_class.evaluate(current_equity: 7_900.0)  # still breaching
    described_class.evaluate(current_equity: 7_800.0)  # still breaching

    expect(SlackNotificationService).to have_received(:alert)
      .with("warning", "MaxDrawdown halt", anything).once
  end

  it "keeps trading halted across those quiet cycles" do
    described_class.evaluate(current_equity: 10_000.0)
    described_class.evaluate(current_equity: 8_000.0)
    described_class.evaluate(current_equity: 7_900.0)

    expect(Trading::Protections.blocked?(symbol: "ANY", side: "long")).to be true
  end

  # Issue #608, observed live 2026-07-31: a $4,987 peak recorded from the CFM
  # balance survived a switch to dry-run, where equity is the $373 paper
  # account. 92.5% "drawdown" — a change of equity SOURCE read as a crash —
  # halted all entries permanently and alerted every 30 minutes. A peak from a
  # different account is not a peak.
  it "discards the peak when the equity regime changes" do
    allow(DryRun).to receive(:active?).and_return(false) # live regime
    described_class.evaluate(current_equity: 4_987.0) # live peak

    allow(DryRun).to receive(:active?).and_return(true) # dry-run flipped on
    described_class.evaluate(current_equity: 373.0) # paper equity now

    expect(Trading::Protections.blocked?(symbol: "ANY", side: "long")).to be false
    expect(SlackNotificationService).not_to have_received(:alert)
  end

  it "still detects a real drawdown within one regime after a flip" do
    allow(DryRun).to receive(:active?).and_return(true)
    described_class.evaluate(current_equity: 373.0)
    described_class.evaluate(current_equity: 300.0) # ~19.6% off the paper peak

    expect(Trading::Protections.blocked?(symbol: "ANY", side: "long")).to be true
  end

  # Defect 2 in #608: the guard documents a 24h lookback and the backtest
  # applies it, but the live peak was a monotonic all-time max — a poisoned or
  # ancient peak could never age out.
  it "lets the peak age out of the lookback window" do
    t0 = Time.current
    described_class.evaluate(current_equity: 10_000.0, now: t0)
    # 25h later: the 10k sample is outside the 24h window; peak is the fresh 8k.
    described_class.evaluate(current_equity: 8_000.0, now: t0 + 25 * 3600)

    expect(Trading::Protections.blocked?(symbol: "ANY", side: "long")).to be false
  end

  it "still halts on a drawdown inside the window" do
    t0 = Time.current
    described_class.evaluate(current_equity: 10_000.0, now: t0)
    described_class.evaluate(current_equity: 8_000.0, now: t0 + 3600)

    expect(Trading::Protections.blocked?(symbol: "ANY", side: "long")).to be true
  end

  # Defect 3 in #608: the alert re-armed every lock TTL — ~48 Slack warnings a
  # day for a stuck breach. A halt is a state: alert on the transition in,
  # then at most one reminder per day.
  it "does not re-alert when the lock expires but the breach persists" do
    t0 = Time.current
    described_class.evaluate(current_equity: 10_000.0, now: t0)
    described_class.evaluate(current_equity: 8_000.0, now: t0 + 60)          # breach -> alert
    Trading::ProtectionLock.clear!                                            # lock TTL expired
    described_class.evaluate(current_equity: 7_900.0, now: t0 + 2000)         # still breached, re-locks

    expect(Trading::Protections.blocked?(symbol: "ANY", side: "long")).to be true
    expect(SlackNotificationService).to have_received(:alert).once
  end

  it "alerts again for a NEW breach episode after the first has recovered" do
    t0 = Time.current
    described_class.evaluate(current_equity: 10_000.0, now: t0)
    described_class.evaluate(current_equity: 8_000.0, now: t0 + 60)           # alert 1
    # a fresh (lower) peak keeps the breach alive inside the rolling window
    described_class.evaluate(current_equity: 9_500.0, now: t0 + 10 * 3600)
    Trading::ProtectionLock.clear!
    described_class.evaluate(current_equity: 8_000.0, now: t0 + 30 * 3600)    # >24h since alert 1

    expect(SlackNotificationService).to have_received(:alert).twice
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
