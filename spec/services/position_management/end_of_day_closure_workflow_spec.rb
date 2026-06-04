# frozen_string_literal: true

require "rails_helper"

RSpec.describe PositionManagement::EndOfDayClosureWorkflow do
  let(:manager) { instance_double(Trading::DayTradingPositionManager) }
  let(:logger) { instance_double(Logger, info: nil, warn: nil, error: nil) }

  subject(:workflow) { described_class.new(manager: manager, logger: logger) }

  before do
    allow(manager).to receive(:force_close_all_day_trading_positions)
  end

  it "closes remaining open positions" do
    allow(manager).to receive(:get_position_summary).and_return({open_count: 2}, {open_count: 0})
    allow(manager).to receive(:force_close_all_day_trading_positions).and_return(2)

    result = workflow.call

    expect(result).to be_success
    expect(result.metadata[:closed_count]).to eq(2)
  end

  it "returns success immediately when no positions are open" do
    allow(manager).to receive(:get_position_summary).and_return({open_count: 0})

    result = workflow.call

    expect(result).to be_success
    expect(result.metadata[:open_count]).to eq(0)
    expect(manager).not_to have_received(:force_close_all_day_trading_positions)
  end
end
