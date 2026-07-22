# frozen_string_literal: true

# Background job that continuously evaluates real-time trading signals
# This job runs on a schedule and uses the RealTimeSignalEvaluator to
# generate alerts when market conditions meet strategy criteria
class RealTimeSignalJob < ApplicationJob
  queue_as :realtime_signals

  def perform(*)
    job_started_at = Time.current.utc
    Rails.logger.info("[RTSJ] Tick start")
    evaluator = RealTimeSignalEvaluator.new(logger: Rails.logger)

    # Evaluate all enabled trading pairs
    cycle_stats = evaluator.evaluate_all_pairs

    # Clean up expired signal alerts
    cleanup_expired_signals

    # Log signal statistics
    log_signal_stats

    EvalTimestampStore.write(Time.current.utc)

    elapsed = (Time.current.utc - job_started_at).round(2)
    Rails.logger.info("[RTSJ] Tick done: cycle_stats=#{cycle_stats.inspect} elapsed=#{elapsed}s")

    # PostHog: Track real-time signal evaluation cycle
    PostHog.capture(
      distinct_id: "system",
      event: "realtime_signal_tick_completed",
      properties: {
        elapsed_seconds: elapsed,
        active_signals: SignalAlert.active.count,
        cycle_stats: cycle_stats.to_s
      }
    )
  end

  private

  def cleanup_expired_signals
    expired_count = SignalAlert.where("expires_at < ?", Time.current.utc)
      .where(alert_status: "active")
      .update_all(alert_status: "expired", updated_at: Time.current.utc)

    Rails.logger.info("[RTSJ] Cleaned up #{expired_count} expired signal alerts") if expired_count > 0

    # Track signal cleanup in Sentry
    if expired_count > 0
      SentryHelper.add_breadcrumb(
        message: "Expired signals cleaned up",
        category: "signal_management",
        level: "info",
        data: {
          expired_count: expired_count,
          operation: "cleanup_expired_signals"
        }
      )
    end
  rescue => e
    Rails.logger.error("[RTSJ] Error cleaning up expired signals: #{e.message}")

    # Track signal cleanup errors
    Sentry.with_scope do |scope|
      scope.set_tag("job_type", "real_time_signal")
      scope.set_tag("operation", "cleanup_expired_signals")
      scope.set_tag("error_type", "signal_cleanup_error")

      Sentry.capture_exception(e)
    end
  end

  def log_signal_stats
    stats = {
      active_signals: SignalAlert.active.count,
      triggered_signals: SignalAlert.triggered.where("alert_timestamp >= ?", 1.hour.ago).count,
      high_confidence_signals: SignalAlert.high_confidence.where("alert_timestamp >= ?", 1.hour.ago).count,
      expired_signals: SignalAlert.expired.where("updated_at >= ?", 1.hour.ago).count
    }

    Rails.logger.info("[RTSJ] Signal stats: #{stats.inspect}")

    # Track signal statistics in Sentry for monitoring
    SentryHelper.add_breadcrumb(
      message: "Signal statistics collected",
      category: "signal_monitoring",
      level: "info",
      data: stats.merge(operation: "log_signal_stats")
    )
  rescue => e
    Rails.logger.error("[RTSJ] Error logging signal stats: #{e.message}")

    # Track stats collection errors
    Sentry.with_scope do |scope|
      scope.set_tag("job_type", "real_time_signal")
      scope.set_tag("operation", "log_signal_stats")
      scope.set_tag("error_type", "stats_collection_error")

      Sentry.capture_exception(e)
    end
  end
end
