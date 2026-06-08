# frozen_string_literal: true

module Trading
  module PositionManagement
    class DayTradingWorkflow < BaseWorkflow
      WORKFLOW_NAME = "day_trading_position_management"

      def initialize(logger: Rails.logger, manager: nil)
        super(logger: logger)
        @manager = manager || Trading::DayTradingPositionManager.new(logger: logger)
      end

      def call
        logger.info("Starting day trading position management workflow")
        add_start_breadcrumb

        expired_closed = close_expired_positions
        approaching_closed = close_approaching_positions
        tp_sl_closed = close_tp_sl_positions
        summary = @manager.get_position_summary

        logger.info("Day trading position summary: #{summary}")

        send_pnl_update(summary)
        log_remaining_open_positions(summary)

        workflow_result(
          workflow: WORKFLOW_NAME,
          status: :success,
          details: {
            expired_closed: expired_closed,
            approaching_closed: approaching_closed,
            tp_sl_closed: tp_sl_closed,
            open_count: summary[:open_count] || 0,
            closed_today_count: summary[:closed_today_count] || 0
          }
        )
      end

      private

      def add_start_breadcrumb
        SentryHelper.add_breadcrumb(
          message: "Day trading position management started",
          category: "trading",
          level: "info",
          data: {
            job_type: "position_management",
            critical: true
          }
        )
      end

      def close_expired_positions
        return 0 unless @manager.positions_need_closure?

        logger.info("Found positions needing immediate closure")
        SentryHelper.add_breadcrumb(
          message: "Closing expired day trading positions",
          category: "trading",
          level: "warning",
          data: {operation: "close_expired_positions"}
        )

        closed_count = @manager.close_expired_positions
        logger.info("Closed #{closed_count} expired positions")

        return closed_count unless closed_count.positive?

        Sentry.with_scope do |scope|
          scope.set_tag("trading_operation", "expired_position_closure")
          scope.set_tag("position_count", closed_count)
          scope.set_context("position_closure", {
            closed_count: closed_count,
            reason: "24_hour_limit_exceeded"
          })

          Sentry.capture_message("Expired day trading positions closed", level: "warning")
        end

        send_alert(
          "warning",
          "Expired Positions Closed",
          "Closed #{closed_count} positions that exceeded the 24-hour day trading limit."
        )

        closed_count
      end

      def close_approaching_positions
        return 0 unless @manager.positions_approaching_closure?

        logger.info("Found positions approaching closure time")
        closed_count = @manager.close_approaching_positions
        logger.info("Closed #{closed_count} approaching positions")

        return closed_count unless closed_count.positive?

        send_alert(
          "info",
          "Positions Approaching Closure",
          "Closed #{closed_count} positions approaching the 24-hour day trading limit."
        )

        closed_count
      end

      def close_tp_sl_positions
        triggered_positions = @manager.check_tp_sl_triggers
        return 0 if triggered_positions.empty?

        logger.info("Found #{triggered_positions.size} positions with triggered TP/SL")
        closed_count = @manager.close_tp_sl_positions
        logger.info("Closed #{closed_count} TP/SL positions")

        return closed_count unless closed_count.positive?

        send_alert(
          "info",
          "TP/SL Positions Closed",
          "Closed #{closed_count} positions due to take profit or stop loss triggers."
        )

        closed_count
      end

      def send_pnl_update(summary)
        closed_today_count = summary[:closed_today_count] || 0
        open_count = summary[:open_count] || 0
        return unless summary[:total_pnl]
        return unless closed_today_count.positive? || open_count > 5

        SlackNotificationService.pnl_update({
          total_pnl: summary[:total_pnl],
          daily_pnl: nil,
          open_positions: open_count,
          closed_today: closed_today_count,
          win_rate: nil
        })
      end

      def log_remaining_open_positions(summary)
        open_count = summary[:open_count] || 0
        return unless open_count.positive?

        logger.info("Remaining open day trading positions: #{open_count}")
        logger.info("Positions needing closure: #{summary[:positions_needing_closure] || 0}")
        logger.info("Positions approaching closure: #{summary[:positions_approaching_closure] || 0}")

        approaching_closure_count = summary[:positions_approaching_closure] || 0
        return unless approaching_closure_count > 3

        send_alert(
          "warning",
          "Multiple Positions Approaching Closure",
          "#{approaching_closure_count} positions are approaching the 24-hour day trading limit."
        )
      end
    end
  end
end
