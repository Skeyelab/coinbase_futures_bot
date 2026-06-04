# frozen_string_literal: true

require "rails_helper"

RSpec.describe PositionManagement::SwingRiskMonitoringWorkflow do
  include ActiveSupport::Testing::TimeHelpers

  let(:manager) { instance_double(Trading::SwingPositionManager) }
  let(:logger) { instance_double(Logger, info: nil, warn: nil, error: nil) }

  subject(:workflow) { described_class.new(manager: manager, logger: logger) }

  before do
    allow(SlackNotificationService).to receive(:alert)
    allow(Sentry).to receive(:with_scope).and_yield(instance_double(Sentry::Scope, set_tag: nil, set_context: nil))
    allow(Sentry).to receive(:capture_exception)
  end

  it "returns success with no positions" do
    allow(manager).to receive(:get_swing_position_summary).and_return({
      total_positions: 0,
      total_exposure: 0,
      unrealized_pnl: 0
    })
    allow(manager).to receive(:get_swing_balance_summary).and_return({})

    result = workflow.call

    expect(result).to be_success
    expect(result.metadata[:total_positions]).to eq(0)
  end

  it "returns failed result instead of raising" do
    error = StandardError.new("boom")
    allow(manager).to receive(:get_swing_position_summary).and_raise(error)

    result = workflow.call

    expect(result).to be_failed
    expect(result.error).to eq("boom")
    expect(Sentry).to have_received(:capture_exception).with(error)
  end

  it "sends margin and concentration alerts with active positions" do
    travel_to Time.zone.parse("2026-06-01 10:15:00 UTC")
    allow(manager).to receive(:get_swing_position_summary).and_return({
      total_positions: 2,
      total_exposure: 100_000.0,
      unrealized_pnl: 400.0,
      positions_by_asset: {"BTC" => {count: 2, pnl: 400.0}},
      risk_metrics: {
        positions_approaching_expiry: 1,
        positions_exceeding_max_hold: 1,
        max_asset_concentration: 0.8,
        avg_hold_time_hours: 120
      }
    })
    allow(manager).to receive(:get_swing_balance_summary).and_return({
      total_usd_balance: 100_000.0,
      initial_margin: 90_000.0,
      available_margin: 10_000.0
    })

    result = workflow.call

    expect(result).to be_success
    expect(SlackNotificationService).to have_received(:alert).with(
      "warning",
      "High Swing Trading Margin Utilization",
      "Swing trading margin utilization is 90.0%. Available margin: $10000.0"
    )
    expect(SlackNotificationService).to have_received(:alert).with(
      "info",
      "Swing Trading Asset Concentration Warning",
      "Asset concentration risk is 80.0%. Consider diversifying swing positions across more assets."
    )
    expect(SlackNotificationService).to have_received(:alert).with(
      "info",
      "Daily Swing Trading Summary",
      include("📊 *Swing Trading Summary*")
    )
  ensure
    travel_back
  end
end
