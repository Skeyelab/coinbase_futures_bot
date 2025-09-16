# frozen_string_literal: true

require "rails_helper"

RSpec.describe SwingPositionCleanupJob, type: :job do
  let(:logger) { instance_double(Logger) }
  let(:swing_manager) { instance_double(Trading::SwingPositionManager) }

  before do
    allow(Rails).to receive(:logger).and_return(logger)
    allow(logger).to receive(:info)
    allow(logger).to receive(:warn)
    allow(logger).to receive(:error)
    allow(Trading::SwingPositionManager).to receive(:new).and_return(swing_manager)
    allow(SentryHelper).to receive(:add_breadcrumb)
  end

  describe "#perform" do
    context "when cleanup operations succeed" do
      before do
        allow(swing_manager).to receive(:cleanup_old_positions).and_return(5)
        allow(swing_manager).to receive(:archive_completed_trades).and_return(3)
        allow(Tick).to receive_message_chain(:where, :delete_all).and_return(100)
        allow(SignalAlert).to receive_message_chain(:where, :delete_all).and_return(25)
      end

      it "performs all cleanup operations successfully" do
        expect { described_class.perform_now }.not_to raise_error

        expect(swing_manager).to have_received(:cleanup_old_positions)
        expect(swing_manager).to have_received(:archive_completed_trades)
        expect(logger).to have_received(:info).with("Cleaned up 5 old closed swing positions")
        expect(logger).to have_received(:info).with("Archived 3 completed swing trades")
        expect(logger).to have_received(:info).with("Deleted 100 stale tick records")
        expect(logger).to have_received(:info).with("Deleted 25 old signal alerts")
      end

      it "logs completion message" do
        described_class.perform_now

        expect(logger).to have_received(:info).with("Swing position cleanup job completed successfully")
      end

      it "adds Sentry breadcrumbs" do
        described_class.perform_now

        expect(SentryHelper).to have_received(:add_breadcrumb).with(
          message: "Swing position cleanup started",
          category: "trading",
          level: "info",
          data: {
            job_type: "swing_position_cleanup",
            priority: "low"
          }
        )

        expect(SentryHelper).to have_received(:add_breadcrumb).with(
          message: "Swing position cleanup completed",
          category: "trading",
          level: "info",
          data: hash_including(operation: "cleanup_completed")
        )
      end
    end

    context "when cleanup operations have errors" do
      let(:error_message) { "Database connection failed" }

      before do
        allow(swing_manager).to receive(:cleanup_old_positions).and_raise(StandardError, error_message)
        allow(swing_manager).to receive(:archive_completed_trades).and_return(0)
        allow(Tick).to receive_message_chain(:where, :delete_all).and_return(0)
        allow(SignalAlert).to receive_message_chain(:where, :delete_all).and_return(0)
      end

      it "continues with other operations despite errors" do
        expect { described_class.perform_now }.not_to raise_error

        expect(swing_manager).to have_received(:cleanup_old_positions)
        expect(swing_manager).to have_received(:archive_completed_trades)
        expect(logger).to have_received(:error).with("Failed to clean up old positions: #{error_message}")
      end
    end

    context "when the job itself fails" do
      let(:job_error) { StandardError.new("Critical job failure") }

      before do
        allow(swing_manager).to receive(:cleanup_old_positions).and_raise(job_error)
        allow(swing_manager).to receive(:archive_completed_trades).and_raise(job_error)
        allow(Sentry).to receive(:with_scope).and_yield(double(set_tag: nil, set_context: nil))
        allow(Sentry).to receive(:capture_exception)
        allow(SlackNotificationService).to receive(:alert)
      end

      it "reports the failure to Sentry and Slack" do
        expect { described_class.perform_now }.to raise_error(job_error)

        expect(Sentry).to have_received(:capture_exception).with(job_error)
        expect(SlackNotificationService).to have_received(:alert).with(
          "warning",
          "Swing Position Cleanup Job Failed",
          "Swing position cleanup job failed: Critical job failure"
        )
      end
    end

    context "when there are significant cleanups" do
      before do
        allow(swing_manager).to receive(:cleanup_old_positions).and_return(500)
        allow(swing_manager).to receive(:archive_completed_trades).and_return(300)
        allow(Tick).to receive_message_chain(:where, :delete_all).and_return(1000)
        allow(SignalAlert).to receive_message_chain(:where, :delete_all).and_return(200)
        allow(SlackNotificationService).to receive(:alert)
      end

      it "sends a notification about large cleanup" do
        described_class.perform_now

        expect(SlackNotificationService).to have_received(:alert).with(
          "info",
          "Large Swing Position Cleanup",
          match(/Cleanup processed 2000 items/)
        )
      end
    end
  end

  describe "queue configuration" do
    it "uses the low priority queue" do
      expect(described_class.queue_name).to eq("low")
    end
  end

  describe "cleanup methods" do
    let(:job_instance) { described_class.new }

    describe "#cleanup_stale_tick_data" do
      it "deletes tick data older than 7 days" do
        cutoff_time = 7.days.ago
        tick_relation = double("tick_relation")

        allow(Tick).to receive(:where).with("observed_at < ?", cutoff_time).and_return(tick_relation)
        allow(tick_relation).to receive(:delete_all).and_return(50)

        result = job_instance.send(:cleanup_stale_tick_data)

        expect(result).to eq(50)
        expect(Tick).to have_received(:where).with("observed_at < ?", cutoff_time)
      end
    end

    describe "#cleanup_old_signal_alerts" do
      it "deletes signal alerts older than 14 days" do
        cutoff_time = 14.days.ago
        alert_relation = double("alert_relation")

        allow(SignalAlert).to receive(:where).with("alert_timestamp < ?", cutoff_time).and_return(alert_relation)
        allow(alert_relation).to receive(:delete_all).and_return(30)

        result = job_instance.send(:cleanup_old_signal_alerts)

        expect(result).to eq(30)
        expect(SignalAlert).to have_received(:where).with("alert_timestamp < ?", cutoff_time)
      end
    end
  end
end
