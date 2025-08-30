# frozen_string_literal: true

class DayTradingPositionManagementJob < ApplicationJob
  queue_as :critical

  def perform
    @logger = Rails.logger
    @manager = Trading::DayTradingPositionManager.new(logger: @logger)

    @logger.info("Starting day trading position management job")

    # Add Sentry breadcrumb for critical trading job
    SentryHelper.add_breadcrumb(
      message: "Day trading position management started",
      category: "trading",
      level: "info",
      data: {
        job_type: "position_management",
        critical: true
      }
    )

    # Check for positions that need immediate closure (opened yesterday)
    if @manager.positions_need_closure?
      @logger.info("Found positions needing immediate closure")

      SentryHelper.add_breadcrumb(
        message: "Closing expired day trading positions",
        category: "trading",
        level: "warning",
        data: {operation: "close_expired_positions"}
      )

      closed_count = @manager.close_expired_positions
      @logger.info("Closed #{closed_count} expired positions")

      if closed_count > 0
        # Track position closures in Sentry
        Sentry.with_scope do |scope|
          scope.set_tag("trading_operation", "expired_position_closure")
          scope.set_tag("position_count", closed_count)
          scope.set_context("position_closure", {
            closed_count: closed_count,
            reason: "24_hour_limit_exceeded"
          })

          Sentry.capture_message("Expired day trading positions closed", level: "warning")
        end

        SlackNotificationService.alert(
          "warning",
          "Expired Positions Closed",
          "Closed #{closed_count} positions that exceeded the 24-hour day trading limit."
        )
      end
    end

    # Check for positions approaching closure time (within 30 minutes of 24 hours)
    if @manager.positions_approaching_closure?
      @logger.info("Found positions approaching closure time")
      closed_count = @manager.close_approaching_positions
      @logger.info("Closed #{closed_count} approaching positions")

      if closed_count > 0
        SlackNotificationService.alert(
          "info",
          "Positions Approaching Closure",
          "Closed #{closed_count} positions approaching the 24-hour day trading limit."
        )
      end
    end

    # Check for take profit/stop loss triggers
    triggered_positions = @manager.check_tp_sl_triggers
    if triggered_positions.any?
      @logger.info("Found #{triggered_positions.size} positions with triggered TP/SL")
      closed_count = @manager.close_tp_sl_positions
      @logger.info("Closed #{closed_count} TP/SL positions")

      if closed_count > 0
        SlackNotificationService.alert(
          "info",
          "TP/SL Positions Closed",
          "Closed #{closed_count} positions due to take profit or stop loss triggers."
        )
      end
    end

    # Get position summary for monitoring
    summary = @manager.get_position_summary
    @logger.info("Day trading position summary: #{summary}")

    # Send periodic PnL update if significant activity
    closed_today_count = summary[:closed_today_count] || 0
    open_count = summary[:open_count] || 0

    if summary[:total_pnl] && (closed_today_count > 0 || open_count > 5)
      SlackNotificationService.pnl_update({
        total_pnl: summary[:total_pnl],
        daily_pnl: nil, # daily_pnl not available in position summary
        open_positions: open_count,
        closed_today: closed_today_count,
        win_rate: nil # win_rate not available in position summary
      })
    end

    # Log any remaining open positions
    if open_count > 0
      @logger.info("Remaining open day trading positions: #{open_count}")
      @logger.info("Positions needing closure: #{summary[:positions_needing_closure] || 0}")
      @logger.info("Positions approaching closure: #{summary[:positions_approaching_closure] || 0}")

      # Alert if too many positions approaching closure
      approaching_closure_count = summary[:positions_approaching_closure] || 0
      if approaching_closure_count > 3
        SlackNotificationService.alert(
          "warning",
          "Multiple Positions Approaching Closure",
          "#{approaching_closure_count} positions are approaching the 24-hour day trading limit."
        )
      end
    end

    @logger.info("Completed day trading position management job")
  rescue => e
    @logger.error("Day trading position management job failed: #{e.message}")
    @logger.error(e.backtrace.join("\n"))

    # Send error alert to Slack
    SlackNotificationService.alert(
      "error",
      "Day Trading Position Management Error",
      "Job failed: #{e.message}"
    )

    raise
  end
end
