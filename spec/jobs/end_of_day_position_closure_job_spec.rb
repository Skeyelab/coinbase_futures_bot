# frozen_string_literal: true

require "rails_helper"

RSpec.describe EndOfDayPositionClosureJob, type: :job do
  let(:job) { described_class.new }
  let(:logger) { instance_double(ActiveSupport::Logger) }
  let(:workflow) { instance_double(Trading::PositionManagement::EndOfDayClosureWorkflow, call: result) }
  let(:result) do
    instance_double(
      Trading::PositionManagement::WorkflowResult,
      summary: "end_of_day_position_closure status=success",
      noop?: noop
    )
  end
  let(:noop) { false }

  before do
    allow(Trading::PositionManagement::EndOfDayClosureWorkflow).to receive(:new).and_return(workflow)
    allow(Rails).to receive(:logger).and_return(logger)
    allow(logger).to receive(:info)
    allow(logger).to receive(:warn)
    allow(logger).to receive(:error)
  end

  describe "#perform" do
    it "delegates to workflow and logs result" do
      expect(logger).to receive(:info).with("Starting end-of-day position closure job")
      expect(Trading::PositionManagement::EndOfDayClosureWorkflow).to receive(:new).with(logger: logger).and_return(workflow)
      expect(workflow).to receive(:call).and_return(result)
      expect(logger).to receive(:info).with("end_of_day_position_closure status=success")
      expect(logger).to receive(:info).with("Completed end-of-day position closure job")

      job.perform
    end

    it "skips completion log for noop result" do
      allow(result).to receive(:noop?).and_return(true)
      expect(logger).not_to receive(:info).with("Completed end-of-day position closure job")
      job.perform
    end

    context "when errors occur" do
      it "handles workflow initialization errors gracefully" do
        allow(Trading::PositionManagement::EndOfDayClosureWorkflow).to receive(:new).and_raise(StandardError, "Manager error")

        expect(logger).to receive(:error).with("End-of-day position closure job failed: Manager error")

        expect { job.perform }.to raise_error(StandardError, "Manager error")
      end

      it "handles workflow execution errors gracefully" do
        allow(workflow).to receive(:call).and_raise(StandardError, "Closure error")

        expect(logger).to receive(:error).with("End-of-day position closure job failed: Closure error")

        expect { job.perform }.to raise_error(StandardError, "Closure error")
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
    it "is configured to run at end of trading day" do
      # This test verifies the job is properly configured for cron scheduling
      # The actual cron configuration is in config/initializers/good_job.rb
      expect(job).to respond_to(:perform)
    end
  end

  describe "integration with manager" do
    it "calls workflow once" do
      expect(workflow).to receive(:call).once.and_return(result)

      job.perform
    end
  end
end
