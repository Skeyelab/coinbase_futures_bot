# frozen_string_literal: true

class SwingPositionCleanupJob < ApplicationJob
  queue_as :low # Lowest priority for cleanup operations

  def perform
    @logger = Rails.logger
    @manager = Trading::SwingPositionManager.new(logger: @logger)

    @logger.info("Starting swing position cleanup job")

    # Add Sentry breadcrumb for cleanup job
    SentryHelper.add_breadcrumb(
      message: "Swing position cleanup started",
      category: "trading",
      level: "info",
      data: {
        job_type: "swing_position_cleanup",
        priority: "low"
      }
    )

    cleanup_stats = {
      old_positions_cleaned: 0,
      archived_trades: 0,
      errors: []
    }

    # Clean up old closed swing positions (older than 30 days)
    begin
      cleaned_count = @manager.cleanup_old_positions
      cleanup_stats[:old_positions_cleaned] = cleaned_count
      @logger.info("Cleaned up #{cleaned_count} old closed swing positions")
    rescue => e
      error_msg = "Failed to clean up old positions: #{e.message}"
      @logger.error(error_msg)
      cleanup_stats[:errors] << error_msg
    end

    # Archive completed swing trades for historical analysis
    begin
      archived_count = @manager.archive_completed_trades
      cleanup_stats[:archived_trades] = archived_count
      @logger.info("Archived #{archived_count} completed swing trades")
    rescue => e
      error_msg = "Failed to archive completed trades: #{e.message}"
      @logger.error(error_msg)
      cleanup_stats[:errors] << error_msg
    end

    # Clean up stale tick data (older than 7 days) to prevent database bloat
    begin
      stale_ticks_deleted = cleanup_stale_tick_data
      cleanup_stats[:stale_ticks_deleted] = stale_ticks_deleted
      @logger.info("Deleted #{stale_ticks_deleted} stale tick records")
    rescue => e
      error_msg = "Failed to clean up stale tick data: #{e.message}"
      @logger.error(error_msg)
      cleanup_stats[:errors] << error_msg
    end

    # Clean up old signal alerts (older than 14 days)
    begin
      old_alerts_deleted = cleanup_old_signal_alerts
      cleanup_stats[:old_alerts_deleted] = old_alerts_deleted
      @logger.info("Deleted #{old_alerts_deleted} old signal alerts")
    rescue => e
      error_msg = "Failed to clean up old signal alerts: #{e.message}"
      @logger.error(error_msg)
      cleanup_stats[:errors] << error_msg
    end

    # Log cleanup summary
    total_cleaned = cleanup_stats.values.select { |v| v.is_a?(Integer) }.sum
    @logger.info("Swing position cleanup completed: #{total_cleaned} total items processed")

    # Add Sentry breadcrumb for cleanup completion
    SentryHelper.add_breadcrumb(
      message: "Swing position cleanup completed",
      category: "trading",
      level: "info",
      data: cleanup_stats.merge(operation: "cleanup_completed")
    )

    # Send notification if there were significant cleanups or errors
    send_cleanup_notification(cleanup_stats) if total_cleaned > 100 || cleanup_stats[:errors].any?

    @logger.info("Swing position cleanup job completed successfully")
  rescue => e
    @logger.error("Swing position cleanup job failed: #{e.message}")
    @logger.error(e.backtrace.join("\n"))

    # Report cleanup job failure to Sentry
    Sentry.with_scope do |scope|
      scope.set_tag("job_type", "swing_position_cleanup")
      scope.set_tag("priority", "low")
      scope.set_context("job_failure", {
        error_class: e.class.to_s,
        error_message: e.message,
        backtrace: e.backtrace&.first(10)
      })

      Sentry.capture_exception(e)
    end

    # Alert via Slack for cleanup job failure (low priority)
    SlackNotificationService.alert(
      "warning",
      "Swing Position Cleanup Job Failed",
      "Swing position cleanup job failed: #{e.message}"
    )

    raise e # Re-raise to ensure job is marked as failed
  end

  private

  def cleanup_stale_tick_data
    # Delete tick data older than 7 days
    cutoff_time = 7.days.ago
    Tick.where("observed_at < ?", cutoff_time).delete_all
  end

  def cleanup_old_signal_alerts
    # Delete signal alerts older than 14 days
    cutoff_time = 14.days.ago
    SignalAlert.where("alert_timestamp < ?", cutoff_time).delete_all
  end

  def send_cleanup_notification(cleanup_stats)
    if cleanup_stats[:errors].any?
      SlackNotificationService.alert(
        "warning",
        "Swing Position Cleanup Issues",
        "Cleanup completed with errors: #{cleanup_stats[:errors].join("; ")}"
      )
    elsif cleanup_stats.values.select { |v| v.is_a?(Integer) }.sum > 1000
      SlackNotificationService.alert(
        "info",
        "Large Swing Position Cleanup",
        "Cleanup processed #{cleanup_stats.values.select { |v| v.is_a?(Integer) }.sum} items: " \
        "#{cleanup_stats[:old_positions_cleaned]} positions, " \
        "#{cleanup_stats[:archived_trades]} trades, " \
        "#{cleanup_stats[:stale_ticks_deleted]} ticks, " \
        "#{cleanup_stats[:old_alerts_deleted]} alerts"
      )
    end
  end
end
