# frozen_string_literal: true

class SwingPositionManagementJob < ApplicationJob
  queue_as :critical

  def perform
    @logger = Rails.logger
    @manager = Trading::SwingPositionManager.new(logger: @logger)

    @logger.info("Starting swing position management job")

    # Add Sentry breadcrumb for critical trading job
    SentryHelper.add_breadcrumb(
      message: "Swing position management started",
      category: "trading",
      level: "info",
      data: {
        job_type: "swing_position_management",
        critical: true
      }
    )

    # Check for positions approaching contract expiry
    expiring_positions = @manager.positions_approaching_expiry
    if expiring_positions.any?
      @logger.warn("Found #{expiring_positions.size} swing positions approaching contract expiry")

      SentryHelper.add_breadcrumb(
        message: "Closing swing positions approaching expiry",
        category: "trading",
        level: "warning",
        data: {operation: "close_expiring_positions", count: expiring_positions.size}
      )

      closed_count = @manager.close_expiring_positions
      @logger.info("Closed #{closed_count} positions approaching expiry")

      if closed_count > 0
        Sentry.with_scope do |scope|
          scope.set_tag("trading_operation", "swing_expiry_closure")
          scope.set_tag("position_count", closed_count)
          scope.set_context("position_closure", {
            closed_count: closed_count,
            reason: "contract_expiry_approaching"
          })

          Sentry.capture_message("Swing positions closed due to approaching expiry", level: "warning")
        end

        SlackNotificationService.alert(
          "warning",
          "Swing Positions Closed - Contract Expiry",
          "Closed #{closed_count} swing positions approaching contract expiry."
        )
      end
    end

    # Check for positions exceeding maximum hold period
    max_hold_positions = @manager.positions_exceeding_max_hold
    if max_hold_positions.any?
      @logger.warn("Found #{max_hold_positions.size} swing positions exceeding max hold period")

      closed_count = @manager.close_max_hold_positions
      @logger.info("Closed #{closed_count} positions exceeding max hold")

      if closed_count > 0
        SlackNotificationService.alert(
          "warning",
          "Swing Positions Closed - Max Hold Exceeded",
          "Closed #{closed_count} swing positions that exceeded maximum holding period."
        )
      end
    end

    # Check for take profit/stop loss triggers
    tp_sl_triggers = @manager.check_swing_tp_sl_triggers
    if tp_sl_triggers.any?
      @logger.info("Found #{tp_sl_triggers.size} swing positions with TP/SL triggers")

      closed_count = @manager.close_tp_sl_positions
      @logger.info("Closed #{closed_count} positions via TP/SL")

      if closed_count > 0
        SlackNotificationService.alert(
          "info",
          "Swing Positions Closed - TP/SL Triggered",
          "Closed #{closed_count} swing positions that hit take profit or stop loss levels."
        )
      end
    end

    # Check risk limits and alert if violations detected
    risk_check = @manager.check_swing_risk_limits
    if risk_check[:risk_status] == "violations_detected"
      @logger.warn("Swing trading risk limit violations detected")

      violations = risk_check[:violations].map { |v| v[:message] }.join("; ")

      Sentry.with_scope do |scope|
        scope.set_tag("trading_operation", "swing_risk_violation")
        scope.set_context("risk_violations", risk_check[:violations])

        Sentry.capture_message("Swing trading risk limit violations detected", level: "warning")
      end

      SlackNotificationService.alert(
        "warning",
        "Swing Trading Risk Violations",
        "Risk limit violations detected: #{violations}"
      )
    end

    @logger.info("Swing position management job completed successfully")
  rescue => e
    @logger.error("Swing position management job failed: #{e.message}")
    @logger.error(e.backtrace.join("\n"))

    # Report critical trading job failure to Sentry
    Sentry.with_scope do |scope|
      scope.set_tag("job_type", "swing_position_management")
      scope.set_tag("critical", true)
      scope.set_context("job_failure", {
        error_class: e.class.to_s,
        error_message: e.message,
        backtrace: e.backtrace&.first(10)
      })

      Sentry.capture_exception(e)
    end

    # Alert via Slack for critical job failure
    SlackNotificationService.alert(
      "critical",
      "Swing Position Management Job Failed",
      "Critical swing position management job failed: #{e.message}"
    )

    raise e # Re-raise to ensure job is marked as failed
  end
end
