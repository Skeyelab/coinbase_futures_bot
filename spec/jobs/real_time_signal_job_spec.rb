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

    before do
      create(:signal_alert, alert_status: "active", confidence: 80, alert_timestamp: 10.minutes.ago)
      create(:signal_alert, alert_status: "active", confidence: 65, alert_timestamp: 2.hours.ago)
      create(:signal_alert, alert_status: "triggered", confidence: 75, alert_timestamp: 20.minutes.ago)
      create(:signal_alert, alert_status: "expired", confidence: 85, alert_timestamp: 30.minutes.ago)
      create(:signal_alert, alert_status: "cancelled", confidence: 90, alert_timestamp: 15.minutes.ago)
    end

    it "logs counts from persisted signal alerts" do
      expected_stats = {
        active_signals: 2,
        triggered_signals: 1,
        high_confidence_signals: 4,
        expired_signals: 1
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

    it "can be run synchronously for local orchestration" do
      allow(RealTimeSignalEvaluator).to receive(:new).and_return(evaluator)
      allow(evaluator).to receive(:evaluate_all_pairs)
      allow_any_instance_of(described_class).to receive(:cleanup_expired_signals)
      allow_any_instance_of(described_class).to receive(:log_signal_stats)

      expect { described_class.perform_now }.not_to raise_error
    end
  end
end
