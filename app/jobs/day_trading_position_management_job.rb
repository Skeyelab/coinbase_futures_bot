# frozen_string_literal: true

class DayTradingPositionManagementJob < ApplicationJob
  queue_as :critical

  def perform
    @logger = Rails.logger
    @manager = Trading::DayTradingPositionManager.new(logger: @logger)

    @logger.info("Starting day trading position management job")

    # Check for positions that need immediate closure (opened yesterday)
    if @manager.positions_need_closure?
      @logger.info("Found positions needing immediate closure")
      closed_count = @manager.close_expired_positions
      @logger.info("Closed #{closed_count} expired positions")
    end

    # Check for positions approaching closure time (within 30 minutes of 24 hours)
    if @manager.positions_approaching_closure?
      @logger.info("Found positions approaching closure time")
      closed_count = @manager.close_approaching_positions
      @logger.info("Closed #{closed_count} approaching positions")
    end

    # Check for take profit/stop loss triggers
    triggered_positions = @manager.check_tp_sl_triggers
    if triggered_positions.any?
      @logger.info("Found #{triggered_positions.size} positions with triggered TP/SL")
      closed_count = @manager.close_tp_sl_positions
      @logger.info("Closed #{closed_count} TP/SL positions")
    end

    # Get position summary for monitoring
    summary = @manager.get_position_summary
    @logger.info("Day trading position summary: #{summary}")

    # Log any remaining open positions
    if summary[:open_count] > 0
      @logger.info("Remaining open day trading positions: #{summary[:open_count]}")
      @logger.info("Positions needing closure: #{summary[:positions_needing_closure]}")
      @logger.info("Positions approaching closure: #{summary[:positions_approaching_closure]}")
    end

    @logger.info("Completed day trading position management job")
  rescue => e
    @logger.error("Day trading position management job failed: #{e.message}")
    @logger.error(e.backtrace.join("\n"))
    raise
  end
end