# frozen_string_literal: true

require "rails_helper"

RSpec.describe PositionManagement::ContractExpiryMonitoringWorkflow do
  let(:expiry_manager) { instance_double(ContractExpiryManager) }
  let(:logger) { instance_double(Logger, info: nil, warn: nil, error: nil) }

  subject(:workflow) { described_class.new(expiry_manager: expiry_manager, logger: logger) }

  before do
    allow(SlackNotificationService).to receive(:alert)
  end

  it "returns structured success result for regular monitoring" do
    allow(expiry_manager).to receive(:generate_expiry_report).and_return({
      total_positions: 0,
      positions_with_known_expiry: 0,
      expiring_today: 0,
      expiring_tomorrow: 0,
      expiring_within_week: 0,
      expired: 0,
      by_days: []
    })
    allow(expiry_manager).to receive(:positions_approaching_expiry).and_return([])
    allow(expiry_manager).to receive(:check_margin_requirements_near_expiry).and_return([])
    allow(expiry_manager).to receive(:validate_expiry_dates).and_return([])

    result = workflow.call(buffer_days: 2)

    expect(result).to be_success
    expect(result.metadata[:buffer_days]).to eq(2)
    expect(result.workflow).to eq("contract_expiry_monitoring")
  end

  it "raises and alerts when regular monitoring fails" do
    allow(expiry_manager).to receive(:generate_expiry_report).and_raise(StandardError, "boom")

    expect { workflow.call }.to raise_error(StandardError, "boom")
    expect(SlackNotificationService).to have_received(:alert).with(
      "error",
      "Contract Expiry Monitoring Failed",
      "Critical workflow failed: boom. Manual intervention may be required."
    )
  end
end
