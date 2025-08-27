# frozen_string_literal: true

# Background job that continuously evaluates real-time trading signals
# This job runs on a schedule and uses the RealTimeSignalEvaluator to
# generate alerts when market conditions meet strategy criteria
class RealTimeSignalJob < ApplicationJob
  queue_as :realtime_signals

  def perform(*args)
    evaluator = RealTimeSignalEvaluator.new(logger: Rails.logger)

    # Evaluate all enabled trading pairs
    evaluator.evaluate_all_pairs

    # Clean up expired signal alerts
    cleanup_expired_signals

    # Log signal statistics
    log_signal_stats
  end

  private

  def cleanup_expired_signals
    expired_count = SignalAlert.where("expires_at < ?", Time.current.utc)
      .where(alert_status: "active")
      .update_all(alert_status: "expired", updated_at: Time.current.utc)

    Rails.logger.info("[RTSJ] Cleaned up #{expired_count} expired signal alerts") if expired_count > 0
  rescue => e
    Rails.logger.error("[RTSJ] Error cleaning up expired signals: #{e.message}")
  end

  def log_signal_stats
    stats = {
      active_signals: SignalAlert.active.count,
      triggered_signals: SignalAlert.triggered.where("alert_timestamp >= ?", 1.hour.ago).count,
      high_confidence_signals: SignalAlert.high_confidence.where("alert_timestamp >= ?", 1.hour.ago).count,
      expired_signals: SignalAlert.expired.where("updated_at >= ?", 1.hour.ago).count
    }

    Rails.logger.info("[RTSJ] Signal stats: #{stats.inspect}")
  rescue => e
    Rails.logger.error("[RTSJ] Error logging signal stats: #{e.message}")
  end

  # Class methods for job management
  def self.schedule_realtime_evaluation(interval_seconds: 30)
    # Remove existing scheduled jobs for this class
    GoodJob::Job.where(job_class: name, finished_at: nil).delete_all

    # Schedule new job to run every interval
    set(wait: interval_seconds.seconds).perform_later
  end
  private_class_method :schedule_realtime_evaluation

  def self.start_realtime_evaluation(interval_seconds: 30)
    Rails.logger.info("[RTSJ] Starting real-time signal evaluation (interval: #{interval_seconds}s)")

    # Schedule the first job
    schedule_realtime_evaluation(interval_seconds: interval_seconds)

    # Start a loop that continuously schedules the next job
    Thread.new do
      loop do
        sleep interval_seconds
        schedule_realtime_evaluation(interval_seconds: interval_seconds)
      end
    end
  end
  private_class_method :start_realtime_evaluation
end
