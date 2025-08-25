# frozen_string_literal: true

class PositionCloseJob < ApplicationJob
  queue_as :critical

  def perform(position_id:, reason:, priority: "normal")
    @position = Position.find(position_id)
    @reason = reason
    @logger = Rails.logger
    
    @logger.info("[PCJ] Closing position #{position_id} (#{@position.product_id}) - Reason: #{reason}")
    
    return unless @position.open?
    
    positions_service = Trading::CoinbasePositions.new(logger: @logger)
    
    # Close the position
    result = positions_service.close_position(
      product_id: @position.product_id,
      size: @position.size
    )
    
    if result[:success]
      # Update position record
      @position.update!(
        status: "CLOSED",
        close_time: Time.current,
        pnl: calculate_pnl(result)
      )
      
      @logger.info("[PCJ] Successfully closed position #{position_id}: #{@reason}")
      send_closure_alert
    else
      @logger.error("[PCJ] Failed to close position #{position_id}: #{result[:error]}")
      
      # Retry if it's a critical closure (stop loss, take profit)
      if %w[stop_loss take_profit time_limit].include?(@reason)
        @logger.info("[PCJ] Retrying critical position closure in 30 seconds")
        PositionCloseJob.set(wait: 30.seconds).perform_later(
          position_id: position_id,
          reason: "#{reason}_retry",
          priority: "critical"
        )
      end
    end
  rescue ActiveRecord::RecordNotFound
    @logger.warn("[PCJ] Position #{position_id} not found - may have been closed already")
  rescue => e
    @logger.error("[PCJ] Error closing position #{position_id}: #{e.message}")
    
    # Retry critical closures
    if %w[stop_loss take_profit time_limit].include?(@reason)
      @logger.info("[PCJ] Retrying critical position closure due to error")
      PositionCloseJob.set(wait: 1.minute).perform_later(
        position_id: position_id,
        reason: "#{reason}_error_retry",
        priority: "critical"
      )
    end
  end

  private

  def calculate_pnl(result)
    # Extract P&L from the closure result
    # This would be implemented based on the actual API response format
    result[:pnl] || 0.0
  end

  def send_closure_alert
    asset = extract_asset_from_product_id(@position.product_id)
    pnl_status = @position.pnl && @position.pnl > 0 ? "PROFIT" : "LOSS"
    
    @logger.info("[ALERT] CLOSED: #{@position.side} #{@position.size} contracts of #{@position.product_id} - #{@reason.upcase} - #{pnl_status}: $#{@position.pnl || 0}")
  end

  def extract_asset_from_product_id(product_id)
    if product_id.start_with?("BIT-")
      "BTC"
    elsif product_id.start_with?("ET-")
      "ETH"
    else
      product_id.split("-").first
    end
  end
end