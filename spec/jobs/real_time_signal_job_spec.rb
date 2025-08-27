# frozen_string_literal: true

require "rails_helper"

RSpec.describe RealTimeSignalJob, type: :job do
  let(:evaluator) { instance_double(RealTimeSignalEvaluator) }
  let(:logger) { instance_double(Logger) }

  before do
    allow(Rails).to receive(:logger).and_return(logger)
    allow(logger).to receive(:info)
    allow(logger).to receive(:error)
  end

  describe "#perform" do
    let(:job) { described_class.new }

    before do
      allow(RealTimeSignalEvaluator).to receive(:new).and_return(evaluator)
      allow(evaluator).to receive(:evaluate_all_pairs)
      allow(job).to receive(:cleanup_expired_signals)
      allow(job).to receive(:log_signal_stats)
    end

    it "creates a RealTimeSignalEvaluator" do
      expect(RealTimeSignalEvaluator).to receive(:new).with(logger: Rails.logger)

      job.perform
    end

    it "calls evaluate_all_pairs on the evaluator" do
      expect(evaluator).to receive(:evaluate_all_pairs)

      job.perform
    end

    it "cleans up expired signals" do
      expect(job).to receive(:cleanup_expired_signals)

      job.perform
    end

    it "logs signal statistics" do
      expect(job).to receive(:log_signal_stats)

      job.perform
    end

    it "executes all steps in the correct order" do
      expect(RealTimeSignalEvaluator).to receive(:new).ordered
      expect(evaluator).to receive(:evaluate_all_pairs).ordered
      expect(job).to receive(:cleanup_expired_signals).ordered
      expect(job).to receive(:log_signal_stats).ordered

      job.perform
    end
  end

  describe "#cleanup_expired_signals" do
    let(:job) { described_class.new }

    context "when expired signals exist" do
      before do
        create(:signal_alert, expires_at: 1.hour.ago, alert_status: "active")
      end

      it "updates expired signals to expired status" do
        expect do
          job.send(:cleanup_expired_signals)
        end.to change { SignalAlert.where(alert_status: "expired").count }.by(1)
      end

      it "logs the number of cleaned up signals" do
        expect(logger).to receive(:info).with("[RTSJ] Cleaned up 1 expired signal alerts")

        job.send(:cleanup_expired_signals)
      end
    end

    context "when no expired signals exist" do
      before do
        create(:signal_alert, expires_at: 1.hour.from_now, alert_status: "active")
      end

      it "does not log cleanup message" do
        expect(logger).not_to receive(:info)

        job.send(:cleanup_expired_signals)
      end
    end
  end

  describe "#log_signal_stats" do
    let(:job) { described_class.new }

    let(:mock_active_scope) { double(count: 12) }
    let(:mock_triggered_scope) { double(where: double(count: 8)) }
    let(:mock_high_confidence_scope) { double(where: double(count: 5)) }
    let(:mock_expired_scope) { double(where: double(count: 3)) }

    before do
      allow(SignalAlert).to receive(:active).and_return(mock_active_scope)
      allow(SignalAlert).to receive(:triggered).and_return(mock_triggered_scope)
      allow(SignalAlert).to receive(:high_confidence).and_return(mock_high_confidence_scope)
      allow(SignalAlert).to receive(:expired).and_return(mock_expired_scope)
    end

    it "collects active signals count" do
      expect(SignalAlert).to receive(:active)
      expect(mock_active_scope).to receive(:count)

      job.send(:log_signal_stats)
    end

    it "collects triggered signals count from last hour" do
      expect(SignalAlert).to receive(:triggered)
      expect(mock_triggered_scope).to receive(:where).with("alert_timestamp >= ?", anything)

      job.send(:log_signal_stats)
    end

    it "collects high confidence signals count from last hour" do
      expect(SignalAlert).to receive(:high_confidence)
      expect(mock_high_confidence_scope).to receive(:where).with("alert_timestamp >= ?", anything)

      job.send(:log_signal_stats)
    end

    it "collects expired signals count from last hour" do
      expect(SignalAlert).to receive(:expired)
      expect(mock_expired_scope).to receive(:where).with("updated_at >= ?", anything)

      job.send(:log_signal_stats)
    end

    it "logs the complete statistics" do
      expected_stats = {
        active_signals: 12,
        triggered_signals: 8,
        high_confidence_signals: 5,
        expired_signals: 3
      }

      expect(logger).to receive(:info).with("[RTSJ] Signal stats: #{expected_stats.inspect}")

      job.send(:log_signal_stats)
    end

    context "when statistics logging fails" do
      before do
        allow(SignalAlert).to receive(:active).and_raise(StandardError.new("Stats error"))
      end

      it "logs the error" do
        expect(logger).to receive(:error).with("[RTSJ] Error logging signal stats: Stats error")

        job.send(:log_signal_stats)
      end

      it "does not raise the error" do
        expect { job.send(:log_signal_stats) }.not_to raise_error
      end
    end
  end

  describe ".schedule_realtime_evaluation" do
    before do
      allow(GoodJob::Job).to receive(:where).and_return(double(delete_all: 5))
      allow(described_class).to receive(:set).and_return(double(perform_later: true))
    end

    it "removes existing scheduled jobs for this class" do
      expect(GoodJob::Job).to receive(:where)
        .with(job_class: "RealTimeSignalJob", finished_at: nil)
        .and_return(double(delete_all: 5))

      described_class.send(:schedule_realtime_evaluation, interval_seconds: 30)
    end

    it "schedules a new job with the specified interval" do
      expect(described_class).to receive(:set).with(wait: 30.seconds)
      expect(described_class.set(wait: 30.seconds)).to receive(:perform_later)

      described_class.send(:schedule_realtime_evaluation, interval_seconds: 30)
    end

    it "uses default interval of 30 seconds" do
      expect(described_class).to receive(:set).with(wait: 30.seconds)

      described_class.send(:schedule_realtime_evaluation)
    end

    it "accepts custom interval" do
      expect(described_class).to receive(:set).with(wait: 60.seconds)

      described_class.send(:schedule_realtime_evaluation, interval_seconds: 60)
    end
  end

  describe ".start_realtime_evaluation" do
    before do
      allow(described_class).to receive(:schedule_realtime_evaluation)
      allow(Thread).to receive(:new).and_return(double(join: nil))
    end

    it "logs the start of real-time evaluation" do
      expect(logger).to receive(:info).with("[RTSJ] Starting real-time signal evaluation (interval: 30s)")

      described_class.send(:start_realtime_evaluation, interval_seconds: 30)
    end

    it "schedules the first job" do
      expect(described_class).to receive(:schedule_realtime_evaluation).with(interval_seconds: 30)

      described_class.send(:start_realtime_evaluation, interval_seconds: 30)
    end

    it "starts a background thread for continuous scheduling" do
      expect(Thread).to receive(:new)

      described_class.send(:start_realtime_evaluation, interval_seconds: 30)
    end
  end

  describe "job configuration" do
    it "is configured to use the realtime_signals queue" do
      expect(described_class.queue_name).to eq("realtime_signals")
    end

    it "inherits from ApplicationJob" do
      expect(described_class.superclass).to eq(ApplicationJob)
    end
  end

  describe "error handling" do
    let(:job) { described_class.new }

    context "when RealTimeSignalEvaluator initialization fails" do
      before do
        allow(RealTimeSignalEvaluator).to receive(:new).and_raise(StandardError.new("Evaluator init failed"))
      end

      it "raises the error" do
        expect { job.perform }.to raise_error(StandardError, "Evaluator init failed")
      end
    end

    context "when evaluate_all_pairs fails" do
      before do
        allow(RealTimeSignalEvaluator).to receive(:new).and_return(evaluator)
        allow(evaluator).to receive(:evaluate_all_pairs).and_raise(StandardError.new("Evaluation failed"))
      end

      it "raises the error" do
        expect { job.perform }.to raise_error(StandardError, "Evaluation failed")
      end
    end
  end

  describe "integration with GoodJob" do
    it "can be enqueued as a GoodJob" do
      expect do
        described_class.perform_later
      end.not_to raise_error
    end

    it "defines private job scheduling methods" do
      expect(described_class.private_methods).to include(:schedule_realtime_evaluation)
      expect(described_class.private_methods).to include(:start_realtime_evaluation)
    end
  end
end
