# frozen_string_literal: true

module Trading
  module PositionManagement
    class EndOfDayClosureWorkflow < BaseWorkflow
      WORKFLOW_NAME = "end_of_day_position_closure"

      def initialize(logger: Rails.logger, manager: nil)
        super(logger: logger)
        @manager = manager || Trading::DayTradingPositionManager.new(logger: logger)
      end

      def call
        logger.info("Starting end-of-day position closure workflow")

        summary = @manager.get_position_summary
        logger.info("Current position summary: #{summary}")

        if summary[:open_count].to_i.zero?
          logger.info("No open day trading positions to close")
          return workflow_result(
            workflow: WORKFLOW_NAME,
            status: :noop,
            details: {open_count: 0, closed_count: 0}
          )
        end

        logger.warn("Force closing all remaining day trading positions at end of day")
        closed_count = @manager.force_close_all_day_trading_positions

        status = closed_count.positive? ? :success : :warning

        if closed_count.positive?
          logger.warn("Successfully closed #{closed_count} day trading positions at end of day")
          logger.info("Final position summary: #{@manager.get_position_summary}")
        else
          logger.error("Failed to close any day trading positions at end of day")
        end

        workflow_result(
          workflow: WORKFLOW_NAME,
          status: status,
          details: {open_count: summary[:open_count], closed_count: closed_count}
        )
      end
    end
  end
end
