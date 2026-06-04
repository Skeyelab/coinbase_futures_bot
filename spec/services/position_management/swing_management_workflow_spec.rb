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
