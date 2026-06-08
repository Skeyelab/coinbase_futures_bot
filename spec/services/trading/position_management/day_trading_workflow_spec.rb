# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trading::PositionManagement::DayTradingWorkflow do
  let(:manager) { instance_double(Trading::DayTradingPositionManager) }
  let(:logger) { instance_double(ActiveSupport::Logger, info: nil, error: nil, warn: nil, debug: nil) }

  subject(:workflow) { described_class.new(logger: logger, manager: manager) }

  before do
    allow(SentryHelper).to receive(:add_breadcrumb)
    allow(SlackNotificationService).to receive(:alert)
    allow(SlackNotificationService).to receive(:pnl_update)
    allow(Sentry).to receive(:with_scope).and_yield(instance_double(Sentry::Scope, set_tag: nil, set_context: nil))
    allow(Sentry).to receive(:capture_message)
  end

  it "returns structured result for no-op run" do
    allow(manager).to receive(:positions_need_closure?).and_return(false)
    allow(manager).to receive(:positions_approaching_closure?).and_return(false)
    allow(manager).to receive(:check_tp_sl_triggers).and_return([])
    allow(manager).to receive(:get_position_summary).and_return({
      open_count: 0,
      closed_today_count: 0,
      positions_needing_closure: 0,
      positions_approaching_closure: 0
    })

    result = workflow.call

    expect(result).to have_attributes(
      workflow: "day_trading_position_management",
      status: :success
    )
    expect(result.details).to include(
      expired_closed: 0,
      approaching_closed: 0,
      tp_sl_closed: 0,
      open_count: 0
    )
  end

  it "closes expired positions and alerts" do
    scope = instance_double(Sentry::Scope, set_tag: nil, set_context: nil)

    allow(manager).to receive(:positions_need_closure?).and_return(true)
    allow(manager).to receive(:close_expired_positions).and_return(2)
    allow(manager).to receive(:positions_approaching_closure?).and_return(false)
    allow(manager).to receive(:check_tp_sl_triggers).and_return([])
    allow(manager).to receive(:get_position_summary).and_return({
      open_count: 0,
      closed_today_count: 0,
      positions_needing_closure: 0,
      positions_approaching_closure: 0
    })
    allow(Sentry).to receive(:with_scope).and_yield(scope)

    expect(logger).to receive(:info).with(/Found positions needing immediate closure/)
    expect(logger).to receive(:info).with(/Closed 2 expired positions/)
    expect(SlackNotificationService).to receive(:alert).with(
      "warning",
      "Expired Positions Closed",
      "Closed 2 positions that exceeded the 24-hour day trading limit."
    )

    result = workflow.call

    expect(result.details[:expired_closed]).to eq(2)
  end

  it "closes approaching positions and alerts" do
    allow(manager).to receive(:positions_need_closure?).and_return(false)
    allow(manager).to receive(:positions_approaching_closure?).and_return(true)
    allow(manager).to receive(:close_approaching_positions).and_return(1)
    allow(manager).to receive(:check_tp_sl_triggers).and_return([])
    allow(manager).to receive(:get_position_summary).and_return({
      open_count: 0,
      closed_today_count: 0,
      positions_needing_closure: 0,
      positions_approaching_closure: 0
    })

    expect(SlackNotificationService).to receive(:alert).with(
      "info",
      "Positions Approaching Closure",
      "Closed 1 positions approaching the 24-hour day trading limit."
    )

    result = workflow.call

    expect(result.details[:approaching_closed]).to eq(1)
  end

  it "closes tp/sl positions and alerts" do
    allow(manager).to receive(:positions_need_closure?).and_return(false)
    allow(manager).to receive(:positions_approaching_closure?).and_return(false)
    allow(manager).to receive(:check_tp_sl_triggers).and_return([double(:trigger)])
    allow(manager).to receive(:close_tp_sl_positions).and_return(1)
    allow(manager).to receive(:get_position_summary).and_return({
      open_count: 0,
      closed_today_count: 0,
      positions_needing_closure: 0,
      positions_approaching_closure: 0
    })

    expect(SlackNotificationService).to receive(:alert).with(
      "info",
      "TP/SL Positions Closed",
      "Closed 1 positions due to take profit or stop loss triggers."
    )

    result = workflow.call

    expect(result.details[:tp_sl_closed]).to eq(1)
  end

  it "sends pnl update for significant activity" do
    allow(manager).to receive(:positions_need_closure?).and_return(false)
    allow(manager).to receive(:positions_approaching_closure?).and_return(false)
    allow(manager).to receive(:check_tp_sl_triggers).and_return([])
    allow(manager).to receive(:get_position_summary).and_return({
      open_count: 6,
      closed_today_count: 0,
      total_pnl: 123.45,
      positions_needing_closure: 0,
      positions_approaching_closure: 0
    })

    expect(SlackNotificationService).to receive(:pnl_update).with(
      hash_including(total_pnl: 123.45, open_positions: 6, closed_today: 0)
    )

    workflow.call
  end
end
