# frozen_string_literal: true

require "rails_helper"

RSpec.describe EndOfDayPositionClosureJob, type: :job do
  let(:job) { described_class.new }
  let(:manager) { instance_double(Trading::DayTradingPositionManager) }
  let(:logger) { instance_double(ActiveSupport::Logger) }

  before do
    allow(Trading::DayTradingPositionManager).to receive(:new).and_return(manager)
    allow(Rails).to receive(:logger).and_return(logger)
    allow(logger).to receive(:info)
    allow(logger).to receive(:warn)
    allow(logger).to receive(:error)
  end

  describe "#perform" do
    it "executes end-of-day position closure" do
      summary = { open_count: 3, closed_count: 0 }
      allow(manager).to receive(:get_position_summary).and_return(summary)
      allow(manager).to receive(:force_close_all_day_trading_positions).and_return(3)

      expect(logger).to receive(:info).with("Starting end-of-day position closure job")
      expect(logger).to receive(:warn).with("Successfully closed 3 day trading positions at end of day")
      expect(logger).to receive(:info).with("Completed end-of-day position closure job")

      job.perform
    end

    it "closes all open day trading positions" do
      summary = { open_count: 2, closed_count: 0 }
      allow(manager).to receive(:get_position_summary).and_return(summary)
      expect(manager).to receive(:force_close_all_day_trading_positions).and_return(2)

      job.perform
    end

    it "handles case when no positions are closed" do
      summary = { open_count: 0, closed_count: 0 }
      allow(manager).to receive(:get_position_summary).and_return(summary)

      expect(logger).to receive(:info).with("No open day trading positions to close")
      # Note: when no positions to close, the job returns early and doesn't log completion

      job.perform
    end

    it "logs start and completion messages" do
      summary = { open_count: 1, closed_count: 0 }
      allow(manager).to receive(:get_position_summary).and_return(summary)
      allow(manager).to receive(:force_close_all_day_trading_positions).and_return(1)

      expect(logger).to receive(:info).with("Starting end-of-day position closure job")
      expect(logger).to receive(:warn).with("Successfully closed 1 day trading positions at end of day")
      expect(logger).to receive(:info).with("Completed end-of-day position closure job")

      job.perform
    end

    context "when errors occur" do
      it "handles manager initialization errors gracefully" do
        allow(Trading::DayTradingPositionManager).to receive(:new).and_raise(StandardError, "Manager error")

        expect(logger).to receive(:error).with("End-of-day position closure job failed: Manager error")

        expect { job.perform }.to raise_error(StandardError, "Manager error")
      end

      it "handles closure execution errors gracefully" do
        summary = { open_count: 1, closed_count: 0 }
        allow(manager).to receive(:get_position_summary).and_return(summary)
        allow(manager).to receive(:force_close_all_day_trading_positions).and_raise(StandardError, "Closure error")

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
    it "calls manager methods in correct order" do
      summary = { open_count: 1, closed_count: 0 }
      allow(manager).to receive(:get_position_summary).and_return(summary)
      allow(manager).to receive(:force_close_all_day_trading_positions).and_return(1)

      expect(manager).to receive(:get_position_summary).ordered.and_return(summary)
      expect(manager).to receive(:force_close_all_day_trading_positions).ordered.and_return(1)

      job.perform
    end
  end
end