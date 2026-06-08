# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trading::PositionManagement::SwingRiskMonitoringWorkflow do
  let(:manager) { instance_double(Trading::SwingPositionManager) }
  let(:logger) { instance_double(Logger, info: nil, warn: nil, error: nil) }
  let(:clock) { -> { Time.zone.parse("2024-01-15 10:15:00 UTC") } }

  subject(:workflow) { described_class.new(logger: logger, manager: manager, clock: clock) }

  let(:position_summary) do
    {
      total_positions: 2,
      total_exposure: 100_000.0,
      unrealized_pnl: 5000.0,
      positions_by_asset: {"BTC" => {count: 1, exposure: 60_000.0, pnl: 3000.0}},
      risk_metrics: {
        positions_approaching_expiry: 0,
        positions_exceeding_max_hold: 0,
        max_asset_concentration: 0.6,
        avg_hold_time_hours: 48.0
      }
    }
  end

  let(:balance_summary) do
    {
      total_usd_balance: 500_000.0,
      initial_margin: 80_000.0,
      available_margin: 200_000.0
    }
  end

  before do
    allow(manager).to receive(:get_swing_position_summary).and_return(position_summary)
    allow(manager).to receive(:get_swing_balance_summary).and_return(balance_summary)
    allow(SlackNotificationService).to receive(:alert)
  end

  it "returns noop when no swing positions exist" do
    allow(manager).to receive(:get_swing_position_summary).and_return({
      total_positions: 0,
      total_exposure: 0,
      unrealized_pnl: 0,
      risk_metrics: {}
    })

    result = workflow.call

    expect(logger).to have_received(:info).with("No swing positions to monitor")
    expect(result).to have_attributes(
      workflow: "swing_risk_monitoring",
      status: :noop
    )
  end

  it "logs summary and returns success result for active positions" do
    result = workflow.call

    expect(logger).to have_received(:info).with(
      "Swing position summary: 2 positions, Total exposure: $100000.0, Unrealized PnL: $5000.0"
    )
    expect(logger).to have_received(:info).with("Margin utilization: 16.0%, Available margin: $200000.0")
    expect(result.status).to eq(:success)
    expect(result.details).to include(total_positions: 2, total_exposure: 100_000.0, balance_error: false)
  end

  it "alerts on high margin utilization" do
    allow(manager).to receive(:get_swing_balance_summary).and_return({
      total_usd_balance: 100_000.0,
      initial_margin: 85_000.0,
      available_margin: 15_000.0
    })

    expect(SlackNotificationService).to receive(:alert).with(
      "warning",
      "High Swing Trading Margin Utilization",
      "Swing trading margin utilization is 85.0%. Available margin: $15000.0"
    )

    workflow.call
  end

  it "alerts on asset concentration and sends periodic summary during morning window" do
    allow(manager).to receive(:get_swing_position_summary).and_return({
      total_positions: 1,
      total_exposure: 100_000.0,
      unrealized_pnl: 0,
      positions_by_asset: {"BTC" => {count: 1, pnl: 2500.0}},
      risk_metrics: {
        positions_approaching_expiry: 1,
        positions_exceeding_max_hold: 0,
        max_asset_concentration: 0.8
      }
    })

    expect(SlackNotificationService).to receive(:alert).with(
      "info",
      "Swing Trading Asset Concentration Warning",
      "Asset concentration risk is 80.0%. Consider diversifying swing positions across more assets."
    )
    expect(SlackNotificationService).to receive(:alert).with(
      "info",
      "Daily Swing Trading Summary",
      include("📊 *Swing Trading Summary*")
    )

    workflow.call
  end

  it "logs balance errors and still returns success" do
    allow(manager).to receive(:get_swing_balance_summary).and_return({error: "API connection failed"})

    result = workflow.call

    expect(logger).to have_received(:error).with("Failed to retrieve balance information: API connection failed")
    expect(result.details[:balance_error]).to eq(true)
  end
end
