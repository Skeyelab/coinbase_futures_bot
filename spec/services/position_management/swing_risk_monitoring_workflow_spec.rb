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
    allow(manager).to receive(:get_swing_position_summary).and_raise(StandardError, "boom")

    result = workflow.call

    expect(result).to be_failed
    expect(result.error).to eq("boom")
  end
end
