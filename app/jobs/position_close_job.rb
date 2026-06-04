# frozen_string_literal: true

class PositionCloseJob < ApplicationJob
  queue_as :critical

  CRITICAL_REASONS = %w[stop_loss take_profit time_limit].freeze

  def perform(position_id:, reason:, priority: "normal")
    @reason = reason
    @logger = Rails.logger
    @position = Position.find(position_id)

    @logger.info("[PCJ] Closing position #{position_id} (#{@position.product_id}) - Reason: #{reason}")
    return unless @position.open?

    positions_service = Trading::CoinbasePositions.new(logger: @logger)
    lifecycle = Trading::PositionLifecycle.new(positions_service: positions_service, logger: @logger)
    result = lifecycle.close(@position, reason: reason)

    if result.success?
      @logger.info("[PCJ] Successfully closed position #{position_id}: #{@reason}")
      send_closure_alert
    else
      @logger.error("[PCJ] Failed to close position #{position_id}")
      retry_if_critical(position_id, reason, wait: 30.seconds, suffix: "_retry")
    end
  rescue ActiveRecord::RecordNotFound
    @logger.warn("[PCJ] Position #{position_id} not found - may have been closed already")
  rescue => e
    @logger.error("[PCJ] Error closing position #{position_id}: #{e.message}")
    retry_if_critical(position_id, reason, wait: 1.minute, suffix: "_error_retry")
  end

  private

  def retry_if_critical(position_id, reason, wait:, suffix:)
    return unless CRITICAL_REASONS.include?(@reason)

    @logger.info("[PCJ] Retrying critical position closure")
    PositionCloseJob.set(wait: wait).perform_later(
      position_id: position_id,
      reason: "#{reason}#{suffix}",
      priority: "critical"
    )
  end

  def send_closure_alert
    pnl_status = (@position.pnl && @position.pnl > 0) ? "PROFIT" : "LOSS"
    @logger.info("[ALERT] CLOSED: #{@position.side} #{@position.size} contracts of #{@position.product_id} - #{@reason.upcase} - #{pnl_status}: $#{@position.pnl || 0}")
  end
end
