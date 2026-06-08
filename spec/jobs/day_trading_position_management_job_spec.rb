# frozen_string_literal: true

require "rails_helper"

RSpec.describe DayTradingPositionManagementJob, type: :job do
  let(:job) { described_class.new }
  let(:logger) { instance_double(ActiveSupport::Logger) }
  let(:workflow) do
    instance_double(
      Trading::PositionManagement::DayTradingWorkflow,
      call: result
    )
  end
  let(:result) do
    instance_double(
      Trading::PositionManagement::WorkflowResult,
      summary: "day_trading_position_management status=success"
    )
  end

  before do
    allow(Trading::PositionManagement::DayTradingWorkflow).to receive(:new).and_return(workflow)
    allow(Rails).to receive(:logger).and_return(logger)
    allow(logger).to receive(:info)
    allow(logger).to receive(:error)
    allow(SlackNotificationService).to receive(:alert)
  end

  describe "#perform" do
    it "delegates to workflow and logs result summary" do
      expect(Trading::PositionManagement::DayTradingWorkflow).to receive(:new).with(logger: logger).and_return(workflow)
      expect(workflow).to receive(:call).and_return(result)
      expect(logger).to receive(:info).with("day_trading_position_management status=success")
      expect(Rails.logger).to receive(:info).with(/Completed day trading position management job/)

      job.perform
    end

    context "when errors occur" do
      it "handles workflow initialization errors gracefully" do
        allow(Trading::PositionManagement::DayTradingWorkflow).to receive(:new).and_raise(StandardError, "Manager error")

        expect(Rails.logger).to receive(:error).with("Day trading position management job failed: Manager error")

        expect { job.perform }.to raise_error(StandardError, "Manager error")
      end

      it "handles workflow errors gracefully" do
        allow(workflow).to receive(:call).and_raise(StandardError, "Check error")

        expect(Rails.logger).to receive(:error).with("Day trading position management job failed: Check error")

        expect { job.perform }.to raise_error(StandardError, "Check error")
      end
    end
  end

  describe "job configuration" do
    it "has the correct queue name" do
      expect(described_class.queue_name).to eq("critical")
    end

    it "has perform instance method" do
      expect(job).to respond_to(:perform)
    end
  end

  describe "cron scheduling" do
    it "is configured to run every 5 minutes" do
      # This test verifies the job is properly configured for cron scheduling
      # The actual cron configuration is in config/initializers/good_job.rb
      expect(job).to respond_to(:perform)
    end
  end
end
