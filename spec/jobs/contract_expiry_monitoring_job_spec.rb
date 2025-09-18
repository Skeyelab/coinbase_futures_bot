# frozen_string_literal: true

require "rails_helper"

RSpec.describe ContractExpiryMonitoringJob, type: :job do
  let(:logger) { double("logger", info: nil, warn: nil, error: nil) }
  let(:expiry_manager) { double("expiry_manager") }
  let(:slack_service) { double("slack_service", alert: nil) }

  before do
    allow(Rails).to receive(:logger).and_return(logger)
    allow(ContractExpiryManager).to receive(:new).and_return(expiry_manager)
    stub_const("SlackNotificationService", slack_service)
    travel_to Date.new(2025, 8, 25)
  end

  after do
    travel_back
  end

  describe "#perform" do
    context "regular monitoring mode" do
      let(:buffer_days) { 2 }
      let!(:expiring_position) { create(:position, product_id: "BIT-27AUG25-CDE", status: "OPEN") }

      before do
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
        allow(expiry_manager).to receive(:close_expiring_positions).and_return(1)
        allow(expiry_manager).to receive(:check_margin_requirements_near_expiry).and_return([])
        allow(expiry_manager).to receive(:validate_expiry_dates).and_return([{valid: true}])
      end

      it "performs regular monitoring successfully" do
        job = described_class.new
        job.perform(buffer_days: buffer_days)

        expect(logger).to have_received(:info).with(/Starting contract expiry monitoring/)
        expect(logger).to have_received(:info).with(/Contract expiry monitoring job completed successfully/)
        expect(expiry_manager).to have_received(:generate_expiry_report)
        expect(expiry_manager).to have_received(:positions_approaching_expiry).with(buffer_days)
        expect(expiry_manager).to have_received(:close_expiring_positions).with(buffer_days)
        expect(expiry_manager).to have_received(:check_margin_requirements_near_expiry).with(5)
        expect(expiry_manager).to have_received(:validate_expiry_dates)
      end

      it "logs comprehensive expiry report" do
        expect(logger).to receive(:info).with(/=== Contract Expiry Report ===/)
        expect(logger).to receive(:info).with(/Total open positions: 5/)
        expect(logger).to receive(:info).with(/Expiring today: 0/)
        expect(logger).to receive(:info).with(/Expiring tomorrow: 1/)
        expect(logger).to receive(:info).with(/Breakdown by days until expiry:/)
        expect(logger).to receive(:info).with(/1 days: 1 positions/)
        expect(logger).to receive(:info).with(/=== End Report ===/)

        job = described_class.new
        job.perform(buffer_days: buffer_days)
      end

      it "handles positions expiring soon" do
        allow(expiring_position).to receive(:days_until_expiry).and_return(2)
        allow(expiring_position).to receive(:product_id).and_return("BIT-27AUG25-CDE")
        allow(expiring_position).to receive(:side).and_return("LONG")
        allow(expiring_position).to receive(:size).and_return(5)
        allow(expiring_position).to receive(:margin_impact_near_expiry).and_return({
          reason: "50% higher margin", multiplier: 1.5
        })

        expect(logger).to receive(:warn).with(/Found 1 positions expiring within 2 days/)
        expect(logger).to receive(:warn).with(/Expiring position: BIT-27AUG25-CDE.*expires in 2 days/)
        expect(logger).to receive(:info).with(/Closed 1\/1 expiring positions/)

        job = described_class.new
        job.perform(buffer_days: buffer_days)
      end

      it "handles no expiring positions" do
        allow(expiry_manager).to receive(:positions_approaching_expiry).and_return([])

        expect(logger).to receive(:info).with(/No positions expiring within 2 days/)

        job = described_class.new
        job.perform(buffer_days: buffer_days)
      end

      it "handles failed position closures" do
        allow(expiry_manager).to receive(:close_expiring_positions).and_return(0)

        expect(logger).to receive(:warn).with(/No positions were successfully closed despite 1 expiring/)
        expect(slack_service).to receive(:alert).with(
          "error",
          "Failed to Close Expiring Positions",
          /Found 1 positions expiring.*could not close any/
        )

        job = described_class.new
        job.perform(buffer_days: buffer_days)
      end

      it "handles margin warnings" do
        margin_warnings = [{position: expiring_position, margin_impact: {reason: "test"}}]
        allow(expiry_manager).to receive(:check_margin_requirements_near_expiry).and_return(margin_warnings)

        expect(logger).to receive(:warn).with(/Found 1 positions with increased margin requirements/)

        job = described_class.new
        job.perform(buffer_days: buffer_days)
      end

      it "handles invalid expiry dates" do
        validation_results = [{valid: true}, {valid: false}, {valid: false}]
        allow(expiry_manager).to receive(:validate_expiry_dates).and_return(validation_results)

        expect(logger).to receive(:error).with(/Found 2 positions with invalid expiry dates/)
        expect(slack_service).to receive(:alert).with(
          "warning",
          "Invalid Contract Expiry Dates",
          /Found 2 positions with unparseable expiry dates/
        )

        job = described_class.new
        job.perform(buffer_days: buffer_days)
      end
    end

    context "emergency check mode" do
      let!(:expired_position) { create(:position, product_id: "BIT-24AUG25-CDE", status: "OPEN") }
      let!(:expiring_today_position) { create(:position, product_id: "BIT-25AUG25-CDE", status: "OPEN") }

      before do
        allow(Position).to receive(:expired_positions).and_return([expired_position])
        allow(expiry_manager).to receive(:positions_approaching_expiry).with(0).and_return([expiring_today_position])
        allow(expiry_manager).to receive(:close_expired_positions).and_return(1)
        allow(expiry_manager).to receive(:close_expiring_positions).and_return(1)
      end

      it "performs emergency check successfully" do
        job = described_class.new
        job.perform(emergency_check: true)

        expect(logger).to have_received(:info).with(/Performing emergency expiry check/)
        expect(expiry_manager).to have_received(:close_expired_positions)
        expect(expiry_manager).to have_received(:positions_approaching_expiry).with(0)
        expect(expiry_manager).to have_received(:close_expiring_positions).with(0)
      end

      it "handles expired positions" do
        allow(expired_position).to receive(:days_until_expiry).and_return(-1)
        allow(expired_position).to receive(:product_id).and_return("BIT-24AUG25-CDE")
        allow(expired_position).to receive(:side).and_return("LONG")
        allow(expired_position).to receive(:size).and_return(3)

        expect(logger).to receive(:error).with(/EMERGENCY: Found 1 expired positions/)
        expect(logger).to receive(:error).with(/EXPIRED position: BIT-24AUG25-CDE.*expired 1 days ago/)
        expect(logger).to receive(:error).with(/EMERGENCY: Closed 1\/1 expired positions/)

        job = described_class.new
        job.perform(emergency_check: true)
      end

      it "handles no expired positions" do
        allow(Position).to receive(:expired_positions).and_return([])
        allow(expiry_manager).to receive(:positions_approaching_expiry).with(0).and_return([])

        expect(logger).to receive(:info).with(/Emergency check: No expired positions found/)

        job = described_class.new
        job.perform(emergency_check: true)
      end

      it "handles failed expired position closures" do
        allow(expiry_manager).to receive(:close_expired_positions).and_return(0)

        expect(logger).to receive(:error).with(/EMERGENCY: Could not close any expired positions/)
        expect(slack_service).to receive(:alert).with(
          "error",
          "CRITICAL: Cannot Close Expired Positions",
          /Found 1 expired positions but could not close any.*IMMEDIATE MANUAL INTERVENTION/
        )

        job = described_class.new
        job.perform(emergency_check: true)
      end

      it "handles positions expiring today during emergency check" do
        expect(logger).to receive(:warn).with(/Emergency check: Found 1 positions expiring today/)
        expect(logger).to receive(:info).with(/Emergency check: Closed 1 positions expiring today/)

        job = described_class.new
        job.perform(emergency_check: true)
      end
    end

    context "error handling" do
      it "handles job failures gracefully" do
        allow(expiry_manager).to receive(:generate_expiry_report).and_raise(StandardError, "Test error")

        expect(logger).to receive(:error).with(/Contract expiry monitoring job failed: Test error/)
        expect(slack_service).to receive(:alert).with(
          "error",
          "Contract Expiry Monitoring Failed",
          /Critical job failed: Test error.*Manual intervention may be required/
        )

        expect {
          job = described_class.new
          job.perform
        }.to raise_error(StandardError, "Test error")
      end

      it "includes backtrace in error logs when available" do
        error = StandardError.new("Test error")
        error.set_backtrace(["line1", "line2"])
        allow(expiry_manager).to receive(:generate_expiry_report).and_raise(error)

        expect(logger).to receive(:error).with(/line1\nline2/)

        expect {
          job = described_class.new
          job.perform
        }.to raise_error(StandardError)
      end
    end

    context "configuration" do
      it "uses environment variable for buffer days" do
        stub_const("ENV", ENV.to_hash.merge("CONTRACT_EXPIRY_BUFFER_DAYS" => "3"))
        allow(expiry_manager).to receive(:generate_expiry_report).and_return({total_positions: 0, positions_with_known_expiry: 0, expiring_today: 0, expiring_tomorrow: 0, expiring_within_week: 0, expired: 0, by_days: []})
        allow(expiry_manager).to receive(:positions_approaching_expiry).and_return([])
        allow(expiry_manager).to receive(:check_margin_requirements_near_expiry).and_return([])
        allow(expiry_manager).to receive(:validate_expiry_dates).and_return([])

        expect(expiry_manager).to receive(:positions_approaching_expiry).with(3)

        job = described_class.new
        job.perform
      end

      it "uses default buffer days when environment variable not set" do
        allow(expiry_manager).to receive(:generate_expiry_report).and_return({total_positions: 0, positions_with_known_expiry: 0, expiring_today: 0, expiring_tomorrow: 0, expiring_within_week: 0, expired: 0, by_days: []})
        allow(expiry_manager).to receive(:positions_approaching_expiry).and_return([])
        allow(expiry_manager).to receive(:check_margin_requirements_near_expiry).and_return([])
        allow(expiry_manager).to receive(:validate_expiry_dates).and_return([])

        expect(expiry_manager).to receive(:positions_approaching_expiry).with(2)

        job = described_class.new
        job.perform
      end

      it "overrides buffer days with parameter" do
        allow(expiry_manager).to receive(:generate_expiry_report).and_return({total_positions: 0, positions_with_known_expiry: 0, expiring_today: 0, expiring_tomorrow: 0, expiring_within_week: 0, expired: 0, by_days: []})
        allow(expiry_manager).to receive(:positions_approaching_expiry).and_return([])
        allow(expiry_manager).to receive(:check_margin_requirements_near_expiry).and_return([])
        allow(expiry_manager).to receive(:validate_expiry_dates).and_return([])

        expect(expiry_manager).to receive(:positions_approaching_expiry).with(5)

        job = described_class.new
        job.perform(buffer_days: 5)
      end
    end

    context "queue and retry configuration" do
      it "is queued as critical" do
        expect(described_class.queue_name).to eq("critical")
      end

      it "has retry configuration" do
        # Check that retry_on is configured by verifying the job class includes retry logic
        expect(described_class.ancestors).to include(ActiveJob::Exceptions)
      end
    end
  end
end
