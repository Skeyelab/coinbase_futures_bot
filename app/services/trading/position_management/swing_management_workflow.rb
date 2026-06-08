# frozen_string_literal: true

module Trading
  module PositionManagement
    class SwingManagementWorkflow < BaseWorkflow
      WORKFLOW_NAME = "swing_position_management"

      def initialize(logger: Rails.logger, manager: nil)
        super(logger: logger)
        @manager = manager || Trading::SwingPositionManager.new(logger: logger)
      end

      def call
        logger.info("Starting swing position management workflow")
        add_start_breadcrumb

        expiring_closed = close_expiring_positions
        max_hold_closed = close_max_hold_positions
        tp_sl_closed = close_tp_sl_positions
        risk_status = check_risk_limits

        workflow_result(
          workflow: WORKFLOW_NAME,
          status: :success,
          details: {
            expiring_closed: expiring_closed,
            max_hold_closed: max_hold_closed,
            tp_sl_closed: tp_sl_closed,
            risk_status: risk_status
          }
        )
      end

      private

      def add_start_breadcrumb
        SentryHelper.add_breadcrumb(
          message: "Swing position management started",
          category: "trading",
          level: "info",
          data: {
            job_type: "swing_position_management",
            critical: true
          }
        )
      end

      def close_expiring_positions
        expiring_positions = @manager.positions_approaching_expiry
        return 0 if expiring_positions.empty?

        logger.warn("Found #{expiring_positions.size} swing positions approaching contract expiry")
        SentryHelper.add_breadcrumb(
          message: "Closing swing positions approaching expiry",
          category: "trading",
          level: "warning",
          data: {operation: "close_expiring_positions", count: expiring_positions.size}
        )

        closed_count = @manager.close_expiring_positions
        logger.info("Closed #{closed_count} positions approaching expiry")

        return closed_count unless closed_count.positive?

        Sentry.with_scope do |scope|
          scope.set_tag("trading_operation", "swing_expiry_closure")
          scope.set_tag("position_count", closed_count)
          scope.set_context("position_closure", {
            closed_count: closed_count,
            reason: "contract_expiry_approaching"
          })

          Sentry.capture_message("Swing positions closed due to approaching expiry", level: "warning")
        end

        send_alert(
          "warning",
          "Swing Positions Closed - Contract Expiry",
          "Closed #{closed_count} swing positions approaching contract expiry."
        )

        closed_count
      end

      def close_max_hold_positions
        max_hold_positions = @manager.positions_exceeding_max_hold
        return 0 if max_hold_positions.empty?

        logger.warn("Found #{max_hold_positions.size} swing positions exceeding max hold period")
        closed_count = @manager.close_max_hold_positions
        logger.info("Closed #{closed_count} positions exceeding max hold")

        return closed_count unless closed_count.positive?

        send_alert(
          "warning",
          "Swing Positions Closed - Max Hold Exceeded",
          "Closed #{closed_count} swing positions that exceeded maximum holding period."
        )

        closed_count
      end

      def close_tp_sl_positions
        tp_sl_triggers = @manager.check_swing_tp_sl_triggers
        return 0 if tp_sl_triggers.empty?

        logger.info("Found #{tp_sl_triggers.size} swing positions with TP/SL triggers")
        closed_count = @manager.close_tp_sl_positions
        logger.info("Closed #{closed_count} positions via TP/SL")

        return closed_count unless closed_count.positive?

        send_alert(
          "info",
          "Swing Positions Closed - TP/SL Triggered",
          "Closed #{closed_count} swing positions that hit take profit or stop loss levels."
        )

        closed_count
      end

      def check_risk_limits
        risk_check = @manager.check_swing_risk_limits
        return risk_check[:risk_status] unless risk_check[:risk_status] == "violations_detected"

        logger.warn("Swing trading risk limit violations detected")
        violations = risk_check[:violations].map { |violation| violation[:message] }.join("; ")

        Sentry.with_scope do |scope|
          scope.set_tag("trading_operation", "swing_risk_violation")
          scope.set_context("risk_violations", {violations: risk_check[:violations]})

          Sentry.capture_message("Swing trading risk limit violations detected", level: "warning")
        end

        send_alert(
          "warning",
          "Swing Trading Risk Violations",
          "Risk limit violations detected: #{violations}"
        )

        risk_check[:risk_status]
      end
    end
  end
end
