# frozen_string_literal: true

class EndOfDayPositionClosureJob < ApplicationJob
  queue_as :critical

  def perform
    @logger = Rails.logger
    @manager = Trading::DayTradingPositionManager.new(logger: @logger)

    @logger.info("Starting end-of-day position closure job")

    # Get current position summary
    summary = @manager.get_position_summary
    @logger.info("Current position summary: #{summary}")

    if summary[:open_count] == 0
      @logger.info("No open day trading positions to close")
      return
    end

    # Force close all remaining day trading positions
    @logger.warn("Force closing all remaining day trading positions at end of day")
    closed_count = @manager.force_close_all_day_trading_positions

    if closed_count > 0
      @logger.warn("Successfully closed #{closed_count} day trading positions at end of day")
      
      # Get final summary
      final_summary = @manager.get_position_summary
      @logger.info("Final position summary: #{final_summary}")
    else
      @logger.error("Failed to close any day trading positions at end of day")
    end

    @logger.info("Completed end-of-day position closure job")
  rescue => e
    @logger.error("End-of-day position closure job failed: #{e.message}")
    @logger.error(e.backtrace.join("\n"))
    
    # This is critical - if we can't close positions, we need to alert
    # In production, you might want to send notifications here
    raise
  end
end