# frozen_string_literal: true

require "rails_helper"

RSpec.describe SwingPositionManagementJob, type: :job do
  let(:logger) { instance_double(Logger) }
  let(:workflow) { instance_double(Trading::PositionManagement::SwingManagementWorkflow, call: result) }
  let(:result) do
    instance_double(
      Trading::PositionManagement::WorkflowResult,
      summary: "swing_position_management status=success"
    )
  end

  before do
    allow(Rails).to receive(:logger).and_return(logger)
    allow(logger).to receive(:info)
    allow(logger).to receive(:warn)
    allow(logger).to receive(:error)
    allow(Trading::PositionManagement::SwingManagementWorkflow).to receive(:new).and_return(workflow)
    allow(SlackNotificationService).to receive(:alert)
  end

  describe "#perform" do
    it "delegates to workflow and logs result summary" do
      expect(Trading::PositionManagement::SwingManagementWorkflow).to receive(:new).with(logger: logger).and_return(workflow)
      expect(workflow).to receive(:call).and_return(result)
      expect(logger).to receive(:info).with("swing_position_management status=success")
      expect(logger).to receive(:info).with("Swing position management job completed successfully")

      subject.perform
    end

    context "when an error occurs" do
      let(:error) { StandardError.new("Test error") }

      before do
        allow(workflow).to receive(:call).and_raise(error)
      end

      it "logs the error and sends critical alert" do
        expect(logger).to receive(:error).with("Swing position management job failed: Test error")
        expect(SlackNotificationService).to receive(:alert).with(
          "critical",
          "Swing Position Management Job Failed",
          "Critical swing position management job failed: Test error"
        )

        expect { subject.perform }.to raise_error(StandardError, "Test error")
      end

      it "captures exception in Sentry" do
        expect(Sentry).to receive(:with_scope)

        expect { subject.perform }.to raise_error(StandardError)
      end
    end
  end
end
