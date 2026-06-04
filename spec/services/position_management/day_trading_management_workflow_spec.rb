# frozen_string_literal: true

require "rails_helper"

RSpec.describe PositionManagement::DayTradingManagementWorkflow do
  let(:manager) { instance_double(Trading::DayTradingPositionManager) }
  let(:logger) { instance_double(Logger, info: nil, error: nil, warn: nil) }

  subject(:workflow) { described_class.new(manager: manager, logger: logger) }

  before do
    allow(SentryHelper).to receive(:add_breadcrumb)
    allow(Sentry).to receive(:with_scope).and_yield(instance_double(Sentry::Scope, set_tag: nil, set_context: nil))
    allow(Sentry).to receive(:capture_message)
    allow(SlackNotificationService).to receive(:alert)
    allow(SlackNotificationService).to receive(:pnl_update)
  end

  it "returns a structured success result" do
    allow(manager).to receive(:positions_need_closure?).and_return(false)
    allow(manager).to receive(:positions_approaching_closure?).and_return(false)
    allow(manager).to receive(:check_tp_sl_triggers).and_return([])
    allow(manager).to receive(:get_position_summary).and_return({open_count: 0, total_pnl: nil})

    result = workflow.call

    expect(result).to be_a(PositionManagement::WorkflowResult)
    expect(result).to be_success
    expect(result.workflow).to eq("day_trading_position_management")
  end

  it "records warning alerts when expired positions are closed" do
    allow(manager).to receive(:positions_need_closure?).and_return(true)
    allow(manager).to receive(:close_expired_positions).and_return(2)
    allow(manager).to receive(:positions_approaching_closure?).and_return(false)
    allow(manager).to receive(:check_tp_sl_triggers).and_return([])
    allow(manager).to receive(:get_position_summary).and_return({open_count: 0, total_pnl: nil})

    result = workflow.call

    expect(SlackNotificationService).to have_received(:alert).with(
      "warning",
      "Expired Positions Closed",
      "Closed 2 positions that exceeded the 24-hour day trading limit."
    )
    expect(result.alerts).to include(hash_including(severity: "warning", title: "Expired Positions Closed"))
  end

  it "raises and alerts on workflow failure" do
    allow(manager).to receive(:positions_need_closure?).and_raise(StandardError, "boom")

    expect {
      workflow.call
    }.to raise_error(StandardError, "boom")

    expect(SlackNotificationService).to have_received(:alert).with(
      "error",
      "Day Trading Position Management Error",
      "Workflow failed: boom"
    )
  end
end
