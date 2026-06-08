# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trading::PositionManagement::ContractExpiryMonitoringWorkflow do
  let(:logger) { double("logger", info: nil, warn: nil, error: nil) }
  let(:expiry_manager) { double("expiry_manager") }
  let(:slack_service) { double("slack_service", alert: nil) }

  subject(:workflow) { described_class.new(logger: logger, expiry_manager: expiry_manager) }

  before do
    stub_const("SlackNotificationService", slack_service)
    travel_to Date.new(2025, 8, 25)
  end

  after do
    travel_back
  end

  it "performs regular monitoring and returns structured result" do
    expiring_position = create(:position, product_id: "BIT-27AUG25-CDE", status: "OPEN")
    allow(expiry_manager).to receive(:generate_expiry_report).and_return({
      total_positions: 5,
      positions_with_known_expiry: 5,
      expiring_today: 0,
      expiring_tomorrow: 1,
      expiring_within_week: 2,
      expired: 0,
      by_days: [[1, 1], [2, 1], [7, 3]]
    })
    allow(expiry_manager).to receive(:positions_approaching_expiry).and_return([expiring_position])
    allow(expiring_position).to receive(:days_until_expiry).and_return(2)
    allow(expiring_position).to receive(:side).and_return("LONG")
    allow(expiring_position).to receive(:size).and_return(5)
    allow(expiring_position).to receive(:margin_impact_near_expiry).and_return({reason: "50% higher margin", multiplier: 1.5})
    allow(expiry_manager).to receive(:close_expiring_positions).and_return(1)
    allow(expiry_manager).to receive(:check_margin_requirements_near_expiry).and_return([])
    allow(expiry_manager).to receive(:validate_expiry_dates).and_return([{valid: true}])

    result = workflow.call(buffer_days: 2)

    expect(logger).to have_received(:warn).with(/Found 1 positions expiring within 2 days/)
    expect(logger).to have_received(:info).with(/Closed 1\/1 expiring positions/)
    expect(result).to have_attributes(
      workflow: "contract_expiry_monitoring",
      status: :success
    )
    expect(result.details).to include(
      expiring_positions: 1,
      closed_count: 1,
      invalid_expiry_dates: 0,
      buffer_days: 2,
      emergency_check: false
    )
  end

  it "alerts when expiring positions cannot be closed" do
    expiring_position = create(:position, product_id: "BIT-27AUG25-CDE", status: "OPEN")
    allow(expiry_manager).to receive(:generate_expiry_report).and_return({
      total_positions: 1,
      positions_with_known_expiry: 1,
      expiring_today: 0,
      expiring_tomorrow: 1,
      expiring_within_week: 1,
      expired: 0,
      by_days: [[1, 1]]
    })
    allow(expiry_manager).to receive(:positions_approaching_expiry).and_return([expiring_position])
    allow(expiring_position).to receive(:days_until_expiry).and_return(1)
    allow(expiring_position).to receive(:side).and_return("LONG")
    allow(expiring_position).to receive(:size).and_return(1)
    allow(expiring_position).to receive(:margin_impact_near_expiry).and_return({reason: "higher margin", multiplier: 1.5})
    allow(expiry_manager).to receive(:close_expiring_positions).and_return(0)
    allow(expiry_manager).to receive(:check_margin_requirements_near_expiry).and_return([])
    allow(expiry_manager).to receive(:validate_expiry_dates).and_return([{valid: true}])

    expect(slack_service).to receive(:alert).with(
      "error",
      "Failed to Close Expiring Positions",
      /Found 1 positions expiring within 2 days but could not close any/
    )

    result = workflow.call(buffer_days: 2)

    expect(result.status).to eq(:warning)
  end

  it "alerts on invalid expiry dates" do
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
    allow(expiry_manager).to receive(:validate_expiry_dates).and_return([{valid: true}, {valid: false}, {valid: false}])

    expect(slack_service).to receive(:alert).with(
      "warning",
      "Invalid Contract Expiry Dates",
      /Found 2 positions with unparseable expiry dates/
    )

    result = workflow.call(buffer_days: 2)

    expect(result.details[:invalid_expiry_dates]).to eq(2)
  end

  it "performs emergency checks and returns structured result" do
    expired_position = create(:position, product_id: "BIT-24AUG25-CDE", status: "OPEN")
    expiring_today_position = create(:position, product_id: "BIT-25AUG25-CDE", status: "OPEN")

    allow(Position).to receive(:expired_positions).and_return([expired_position])
    allow(expired_position).to receive(:days_until_expiry).and_return(-1)
    allow(expired_position).to receive(:side).and_return("LONG")
    allow(expired_position).to receive(:size).and_return(3)
    allow(expiry_manager).to receive(:close_expired_positions).and_return(1)
    allow(expiry_manager).to receive(:positions_approaching_expiry).with(0).and_return([expiring_today_position])
    allow(expiry_manager).to receive(:close_expiring_positions).with(0).and_return(1)

    result = workflow.call(emergency_check: true)

    expect(logger).to have_received(:error).with(/EMERGENCY: Found 1 expired positions/)
    expect(logger).to have_received(:info).with(/Emergency check: Closed 1 positions expiring today/)
    expect(result.status).to eq(:success)
    expect(result.details).to include(
      expired_positions: 1,
      expired_closed_count: 1,
      expiring_today: 1,
      today_closed_count: 1,
      emergency_check: true
    )
  end

  it "alerts when expired positions cannot be closed in emergency mode" do
    expired_position = create(:position, product_id: "BIT-24AUG25-CDE", status: "OPEN")
    allow(Position).to receive(:expired_positions).and_return([expired_position])
    allow(expired_position).to receive(:days_until_expiry).and_return(-1)
    allow(expired_position).to receive(:side).and_return("LONG")
    allow(expired_position).to receive(:size).and_return(3)
    allow(expiry_manager).to receive(:close_expired_positions).and_return(0)
    allow(expiry_manager).to receive(:positions_approaching_expiry).with(0).and_return([])

    expect(slack_service).to receive(:alert).with(
      "error",
      "CRITICAL: Cannot Close Expired Positions",
      /Found 1 expired positions but could not close any/
    )

    result = workflow.call(emergency_check: true)

    expect(result.status).to eq(:warning)
  end
end
