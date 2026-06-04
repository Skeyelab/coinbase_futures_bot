# frozen_string_literal: true

module PositionManagement
  class DayTradingManagementWorkflow
    include AlertPolicy

    attr_reader :logger

    def initialize(manager: Trading::DayTradingPositionManager.new(logger: Rails.logger), logger: Rails.logger)
      @manager = manager
      @logger = logger
    end

    def call
      alerts = []
      metadata = {}

      logger.info("Starting day trading position management workflow")

      SentryHelper.add_breadcrumb(
        message: "Day trading position management started",
        category: "trading",
        level: "info",
        data: {
          job_type: "position_management",
          critical: true
        }
      )

      if @manager.positions_need_closure?
        logger.info("Found positions needing immediate closure")

        SentryHelper.add_breadcrumb(
          message: "Closing expired day trading positions",
          category: "trading",
          level: "warning",
          data: {operation: "close_expired_positions"}
        )

        closed_count = @manager.close_expired_positions
        metadata[:expired_closed_count] = closed_count
        logger.info("Closed #{closed_count} expired positions")

        if closed_count > 0
          Sentry.with_scope do |scope|
            scope.set_tag("trading_operation", "expired_position_closure")
            scope.set_tag("position_count", closed_count)
            scope.set_context("position_closure", {
              closed_count: closed_count,
              reason: "24_hour_limit_exceeded"
            })

            Sentry.capture_message("Expired day trading positions closed", level: "warning")
          end

          notify(
            alerts,
            severity: "warning",
            title: "Expired Positions Closed",
            message: "Closed #{closed_count} positions that exceeded the 24-hour day trading limit."
          )
        end
      end

      if @manager.positions_approaching_closure?
        logger.info("Found positions approaching closure time")
        closed_count = @manager.close_approaching_positions
        metadata[:approaching_closed_count] = closed_count
        logger.info("Closed #{closed_count} approaching positions")

        if closed_count > 0
          notify(
            alerts,
            severity: "info",
            title: "Positions Approaching Closure",
            message: "Closed #{closed_count} positions approaching the 24-hour day trading limit."
          )
        end
      end

      triggered_positions = @manager.check_tp_sl_triggers
      if triggered_positions.any?
        logger.info("Found #{triggered_positions.size} positions with triggered TP/SL")
        closed_count = @manager.close_tp_sl_positions
        metadata[:tp_sl_closed_count] = closed_count
        logger.info("Closed #{closed_count} TP/SL positions")

        if closed_count > 0
          notify(
            alerts,
            severity: "info",
            title: "TP/SL Positions Closed",
            message: "Closed #{closed_count} positions due to take profit or stop loss triggers."
          )
        end
      end

      summary = @manager.get_position_summary
      metadata[:summary] = summary
      logger.info("Day trading position summary: #{summary}")

      closed_today_count = summary[:closed_today_count] || 0
      open_count = summary[:open_count] || 0

      if summary[:total_pnl] && (closed_today_count > 0 || open_count > 5)
        SlackNotificationService.pnl_update({
          total_pnl: summary[:total_pnl],
          daily_pnl: nil,
          open_positions: open_count,
          closed_today: closed_today_count,
          win_rate: nil
        })
      end

      if open_count > 0
        logger.info("Remaining open day trading positions: #{open_count}")
        logger.info("Positions needing closure: #{summary[:positions_needing_closure] || 0}")
        logger.info("Positions approaching closure: #{summary[:positions_approaching_closure] || 0}")

        approaching_closure_count = summary[:positions_approaching_closure] || 0
        if approaching_closure_count > 3
          notify(
            alerts,
            severity: "warning",
            title: "Multiple Positions Approaching Closure",
            message: "#{approaching_closure_count} positions are approaching the 24-hour day trading limit."
          )
        end
      end

      logger.info("Completed day trading position management workflow")

      WorkflowResult.new(
        workflow: "day_trading_position_management",
        status: :success,
        metadata: metadata,
        alerts: alerts
      )
    rescue => e
      logger.error("Day trading position management workflow failed: #{e.message}")
      logger.error(e.backtrace.join("\n"))

      notify(
        alerts,
        severity: "error",
        title: "Day Trading Position Management Error",
        message: "Workflow failed: #{e.message}"
      )

      raise
    end
  end
end
