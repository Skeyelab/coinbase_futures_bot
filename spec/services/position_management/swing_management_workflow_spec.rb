# frozen_string_literal: true

require "rails_helper"

RSpec.describe PositionManagement::SwingManagementWorkflow do
  let(:manager) { instance_double(Trading::SwingPositionManager) }
  let(:logger) { instance_double(Logger, info: nil, warn: nil, error: nil) }
  let(:scope) { instance_double(Sentry::Scope, set_tag: nil, set_context: nil) }

  subject(:workflow) { described_class.new(manager: manager, logger: logger) }

  before do
    allow(SentryHelper).to receive(:add_breadcrumb)
    allow(Sentry).to receive(:with_scope).and_yield(scope)
    allow(Sentry).to receive(:capture_message)
    allow(Sentry).to receive(:capture_exception)
    allow(SlackNotificationService).to receive(:alert)
  end

  it "returns success and sends risk alert when violations are detected" do
    allow(manager).to receive(:positions_approaching_expiry).and_return([])
    allow(manager).to receive(:positions_exceeding_max_hold).and_return([])
    allow(manager).to receive(:check_swing_tp_sl_triggers).and_return([])
    allow(manager).to receive(:check_swing_risk_limits).and_return({
      risk_status: "violations_detected",
      violations: [{message: "Too much exposure"}]
    })

    result = workflow.call

    expect(result).to be_success
    expect(SlackNotificationService).to have_received(:alert).with(
      "warning",
      "Swing Trading Risk Violations",
      "Risk limit violations detected: Too much exposure"
    )
  end

  it "handles expiry, max-hold, and TP/SL branches" do
    allow(manager).to receive(:positions_approaching_expiry).and_return([double(:position)])
    allow(manager).to receive(:close_expiring_positions).and_return(1)
    allow(manager).to receive(:positions_exceeding_max_hold).and_return([double(:position)])
    allow(manager).to receive(:close_max_hold_positions).and_return(2)
    allow(manager).to receive(:check_swing_tp_sl_triggers).and_return([{}])
    allow(manager).to receive(:close_tp_sl_positions).and_return(3)
    allow(manager).to receive(:check_swing_risk_limits).and_return({risk_status: "acceptable", violations: []})

    result = workflow.call

    expect(result).to be_success
    expect(result.metadata[:expiry_closed_count]).to eq(1)
    expect(result.metadata[:max_hold_closed_count]).to eq(2)
    expect(result.metadata[:tp_sl_closed_count]).to eq(3)
    expect(SlackNotificationService).to have_received(:alert).with(
      "warning",
      "Swing Positions Closed - Contract Expiry",
      "Closed 1 swing positions approaching contract expiry."
    )
    expect(SlackNotificationService).to have_received(:alert).with(
      "warning",
      "Swing Positions Closed - Max Hold Exceeded",
      "Closed 2 swing positions that exceeded maximum holding period."
    )
    expect(SlackNotificationService).to have_received(:alert).with(
      "info",
      "Swing Positions Closed - TP/SL Triggered",
      "Closed 3 swing positions that hit take profit or stop loss levels."
    )
  end

  it "raises and sends critical alert when orchestration fails" do
    allow(manager).to receive(:positions_approaching_expiry).and_raise(StandardError, "boom")

    expect { workflow.call }.to raise_error(StandardError, "boom")

    expect(SlackNotificationService).to have_received(:alert).with(
      "critical",
      "Swing Position Management Job Failed",
      "Critical swing position management workflow failed: boom"
    )
  end
end
