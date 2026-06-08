# frozen_string_literal: true

require "rails_helper"

RSpec.describe ContractExpiryMonitoringJob, type: :job do
  let(:logger) { double("logger", info: nil, warn: nil, error: nil) }
  let(:slack_service) { double("slack_service", alert: nil) }
  let(:workflow) { instance_double(Trading::PositionManagement::ContractExpiryMonitoringWorkflow, call: result) }
  let(:result) do
    instance_double(
      Trading::PositionManagement::WorkflowResult,
      summary: "contract_expiry_monitoring status=success"
    )
  end

  before do
    allow(Rails).to receive(:logger).and_return(logger)
    allow(Trading::PositionManagement::ContractExpiryMonitoringWorkflow).to receive(:new).and_return(workflow)
    stub_const("SlackNotificationService", slack_service)
    travel_to Date.new(2025, 8, 25)
  end

  after do
    travel_back
  end

  describe "#perform" do
    it "delegates to workflow in regular mode" do
      described_class.new.perform(buffer_days: 2)

      expect(logger).to have_received(:info).with(/Starting contract expiry monitoring/)
      expect(logger).to have_received(:info).with("contract_expiry_monitoring status=success")
      expect(logger).to have_received(:info).with(/Contract expiry monitoring job completed successfully/)
      expect(Trading::PositionManagement::ContractExpiryMonitoringWorkflow).to have_received(:new).with(logger: logger)
      expect(workflow).to have_received(:call).with(buffer_days: 2, emergency_check: false)
    end

    it "delegates to workflow in emergency mode" do
      described_class.new.perform(emergency_check: true)

      expect(workflow).to have_received(:call).with(buffer_days: nil, emergency_check: true)
    end

    context "error handling" do
      it "handles job failures gracefully" do
        allow(workflow).to receive(:call).and_raise(StandardError, "Test error")

        expect(logger).to receive(:error).with(/Contract expiry monitoring job failed: Test error/)
        expect(slack_service).to receive(:alert).with(
          "error",
          "Contract Expiry Monitoring Failed",
          /Critical job failed: Test error.*Manual intervention may be required/
        )

        expect {
          described_class.new.perform
        }.to raise_error(StandardError, "Test error")
      end

      it "includes backtrace in error logs when available" do
        error = StandardError.new("Test error")
        error.set_backtrace(["line1", "line2"])
        allow(workflow).to receive(:call).and_raise(error)

        expect(logger).to receive(:error).with(/line1\nline2/)

        expect {
          described_class.new.perform
        }.to raise_error(StandardError)
      end
    end

    context "configuration" do
      it "passes default nil buffer to workflow" do
        described_class.new.perform

        expect(workflow).to have_received(:call).with(buffer_days: nil, emergency_check: false)
      end

      it "passes explicit buffer day override through to workflow" do
        described_class.new.perform(buffer_days: 5)

        expect(workflow).to have_received(:call).with(buffer_days: 5, emergency_check: false)
      end
    end

    context "queue and retry configuration" do
      it "is queued as critical" do
        expect(described_class.queue_name).to eq("critical")
      end

      it "has retry configuration" do
        expect(described_class.ancestors).to include(ActiveJob::Exceptions)
      end
    end
  end
end
