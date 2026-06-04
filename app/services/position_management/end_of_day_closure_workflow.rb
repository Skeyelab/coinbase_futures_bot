# frozen_string_literal: true

module PositionManagement
  class EndOfDayClosureWorkflow
    attr_reader :logger

    def initialize(manager: Trading::DayTradingPositionManager.new(logger: Rails.logger), logger: Rails.logger)
      @manager = manager
      @logger = logger
    end

    def call
      logger.info("Starting end-of-day position closure workflow")

      summary = @manager.get_position_summary
      logger.info("Current position summary: #{summary}")

      if summary[:open_count] == 0
        logger.info("No open day trading positions to close")
        return WorkflowResult.new(
          workflow: "end_of_day_position_closure",
          status: :success,
          metadata: {open_count: 0},
          alerts: []
        )
      end

      logger.warn("Force closing all remaining day trading positions at end of day")
      closed_count = @manager.force_close_all_day_trading_positions

      metadata = {
        open_count: summary[:open_count],
        closed_count: closed_count
      }

      if closed_count > 0
        logger.warn("Successfully closed #{closed_count} day trading positions at end of day")
        final_summary = @manager.get_position_summary
        metadata[:final_summary] = final_summary
        logger.info("Final position summary: #{final_summary}")
      else
        logger.error("Failed to close any day trading positions at end of day")
      end

      logger.info("Completed end-of-day position closure workflow")
      WorkflowResult.new(
        workflow: "end_of_day_position_closure",
        status: :success,
        metadata: metadata,
        alerts: []
      )
    rescue => e
      logger.error("End-of-day position closure workflow failed: #{e.message}")
      logger.error(e.backtrace.join("\n"))
      raise
    end
  end
end
