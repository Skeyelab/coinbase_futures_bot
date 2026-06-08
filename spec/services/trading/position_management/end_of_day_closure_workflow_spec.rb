# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trading::PositionManagement::EndOfDayClosureWorkflow do
  let(:manager) { instance_double(Trading::DayTradingPositionManager) }
  let(:logger) { instance_double(ActiveSupport::Logger, info: nil, warn: nil, error: nil) }

  subject(:workflow) { described_class.new(logger: logger, manager: manager) }

  it "returns noop when no positions are open" do
    allow(manager).to receive(:get_position_summary).and_return({open_count: 0, closed_count: 0})

    result = workflow.call

    expect(logger).to have_received(:info).with("No open day trading positions to close")
    expect(result).to have_attributes(
      workflow: "end_of_day_position_closure",
      status: :noop
    )
    expect(result.details).to include(open_count: 0, closed_count: 0)
  end

  it "force closes open positions and returns success result" do
    summary = {open_count: 3, closed_count: 0}
    final_summary = {open_count: 0, closed_count: 3}
    allow(manager).to receive(:get_position_summary).and_return(summary, final_summary)
    allow(manager).to receive(:force_close_all_day_trading_positions).and_return(3)

    result = workflow.call

    expect(logger).to have_received(:warn).with("Force closing all remaining day trading positions at end of day")
    expect(logger).to have_received(:warn).with("Successfully closed 3 day trading positions at end of day")
    expect(result.status).to eq(:success)
    expect(result.details).to include(open_count: 3, closed_count: 3)
  end

  it "returns warning when no positions can be closed" do
    allow(manager).to receive(:get_position_summary).and_return({open_count: 2, closed_count: 0})
    allow(manager).to receive(:force_close_all_day_trading_positions).and_return(0)

    result = workflow.call

    expect(logger).to have_received(:error).with("Failed to close any day trading positions at end of day")
    expect(result.status).to eq(:warning)
    expect(result.details).to include(open_count: 2, closed_count: 0)
  end
end
