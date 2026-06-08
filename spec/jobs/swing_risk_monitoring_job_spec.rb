# frozen_string_literal: true

require "rails_helper"

RSpec.describe SwingRiskMonitoringJob, type: :job do
  let(:logger) { instance_double(Logger) }
  let(:workflow) { instance_double(Trading::PositionManagement::SwingRiskMonitoringWorkflow, call: result) }
  let(:result) do
    instance_double(
      Trading::PositionManagement::WorkflowResult,
      summary: "swing_risk_monitoring status=success",
      noop?: noop
    )
  end
  let(:noop) { false }

  before do
    allow(Rails).to receive(:logger).and_return(logger)
    allow(logger).to receive(:info)
    allow(logger).to receive(:warn)
    allow(logger).to receive(:error)
    allow(Trading::PositionManagement::SwingRiskMonitoringWorkflow).to receive(:new).and_return(workflow)
    allow(SlackNotificationService).to receive(:alert)
  end

  describe "#perform" do
    it "delegates to workflow and logs result summary" do
      expect(Trading::PositionManagement::SwingRiskMonitoringWorkflow).to receive(:new).with(logger: logger).and_return(workflow)
      expect(workflow).to receive(:call).and_return(result)
      expect(logger).to receive(:info).with("swing_risk_monitoring status=success")
      expect(logger).to receive(:info).with("Swing risk monitoring job completed successfully")

      subject.perform
    end

    it "skips completion log for noop result" do
      allow(result).to receive(:noop?).and_return(true)

      expect(logger).not_to receive(:info).with("Swing risk monitoring job completed successfully")

      subject.perform
    end

    context "when an error occurs" do
      let(:error) { StandardError.new("Test error") }

      before do
        allow(workflow).to receive(:call).and_raise(error)
      end

      it "logs the error but does not re-raise" do
        expect(logger).to receive(:error).with("Swing risk monitoring job failed: Test error")

        expect { subject.perform }.not_to raise_error
      end

      it "captures exception in Sentry" do
        expect(Sentry).to receive(:with_scope)

        subject.perform
      end
    end
  end
end
