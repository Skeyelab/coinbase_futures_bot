# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trading::PositionManagement::SwingManagementWorkflow do
  let(:manager) { instance_double(Trading::SwingPositionManager) }
  let(:logger) { instance_double(Logger, info: nil, warn: nil, error: nil) }

  subject(:workflow) { described_class.new(logger: logger, manager: manager) }

  before do
    allow(SentryHelper).to receive(:add_breadcrumb)
    allow(SlackNotificationService).to receive(:alert)
    allow(Sentry).to receive(:capture_message)
    allow(Sentry).to receive(:with_scope).and_yield(instance_double(Sentry::Scope, set_tag: nil, set_context: nil))
  end

  it "returns structured success result when no actions are needed" do
    allow(manager).to receive(:positions_approaching_expiry).and_return([])
    allow(manager).to receive(:positions_exceeding_max_hold).and_return([])
    allow(manager).to receive(:check_swing_tp_sl_triggers).and_return([])
    allow(manager).to receive(:check_swing_risk_limits).and_return({risk_status: "acceptable"})

    result = workflow.call

    expect(result).to have_attributes(
      workflow: "swing_position_management",
      status: :success
    )
    expect(result.details).to include(
      expiring_closed: 0,
      max_hold_closed: 0,
      tp_sl_closed: 0,
      risk_status: "acceptable"
    )
  end

  it "closes expiring positions and alerts" do
    expiring_position = create(:position, day_trading: false, status: "OPEN")
    allow(manager).to receive(:positions_approaching_expiry).and_return([expiring_position])
    allow(manager).to receive(:close_expiring_positions).and_return(1)
    allow(manager).to receive(:positions_exceeding_max_hold).and_return([])
    allow(manager).to receive(:check_swing_tp_sl_triggers).and_return([])
    allow(manager).to receive(:check_swing_risk_limits).and_return({risk_status: "acceptable"})

    expect(SlackNotificationService).to receive(:alert).with(
      "warning",
      "Swing Positions Closed - Contract Expiry",
      "Closed 1 swing positions approaching contract expiry."
    )

    result = workflow.call

    expect(result.details[:expiring_closed]).to eq(1)
  end

  it "closes max-hold positions and alerts" do
    old_position = create(:position, day_trading: false, status: "OPEN", entry_time: 6.days.ago)
    allow(manager).to receive(:positions_approaching_expiry).and_return([])
    allow(manager).to receive(:positions_exceeding_max_hold).and_return([old_position])
    allow(manager).to receive(:close_max_hold_positions).and_return(1)
    allow(manager).to receive(:check_swing_tp_sl_triggers).and_return([])
    allow(manager).to receive(:check_swing_risk_limits).and_return({risk_status: "acceptable"})

    expect(SlackNotificationService).to receive(:alert).with(
      "warning",
      "Swing Positions Closed - Max Hold Exceeded",
      "Closed 1 swing positions that exceeded maximum holding period."
    )

    result = workflow.call

    expect(result.details[:max_hold_closed]).to eq(1)
  end

  it "closes tp/sl positions and alerts" do
    allow(manager).to receive(:positions_approaching_expiry).and_return([])
    allow(manager).to receive(:positions_exceeding_max_hold).and_return([])
    allow(manager).to receive(:check_swing_tp_sl_triggers).and_return([double(:trigger)])
    allow(manager).to receive(:close_tp_sl_positions).and_return(1)
    allow(manager).to receive(:check_swing_risk_limits).and_return({risk_status: "acceptable"})

    expect(SlackNotificationService).to receive(:alert).with(
      "info",
      "Swing Positions Closed - TP/SL Triggered",
      "Closed 1 swing positions that hit take profit or stop loss levels."
    )

    result = workflow.call

    expect(result.details[:tp_sl_closed]).to eq(1)
  end

  it "alerts on risk violations" do
    risk_violations = {
      risk_status: "violations_detected",
      violations: [
        {type: "max_exposure_exceeded", message: "Total swing position exposure exceeds 30.0% limit"}
      ]
    }

    allow(manager).to receive(:positions_approaching_expiry).and_return([])
    allow(manager).to receive(:positions_exceeding_max_hold).and_return([])
    allow(manager).to receive(:check_swing_tp_sl_triggers).and_return([])
    allow(manager).to receive(:check_swing_risk_limits).and_return(risk_violations)

    expect(SlackNotificationService).to receive(:alert).with(
      "warning",
      "Swing Trading Risk Violations",
      "Risk limit violations detected: Total swing position exposure exceeds 30.0% limit"
    )

    result = workflow.call

    expect(result.details[:risk_status]).to eq("violations_detected")
  end
end
