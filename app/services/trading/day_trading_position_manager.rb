# frozen_string_literal: true

module Trading
  # Manages day trading positions with automatic same-day closure
  # This service ensures that all day trading positions are closed before the end of the trading day
  class DayTradingPositionManager
    def initialize(logger: Rails.logger)
      @logger = logger
      @positions_service = CoinbasePositions.new(logger: logger)
      @contract_manager = MarketData::FuturesContractManager.new(logger: logger)
    end

    # Check if any day trading positions need immediate closure
    def positions_need_closure?
      Position.positions_needing_closure.exists?
    end

    # Check if any day trading positions are approaching closure time
    def positions_approaching_closure?
      Position.positions_approaching_closure.exists?
    end

    # Get all day trading positions that need closure
    def positions_needing_closure
      Position.positions_needing_closure.includes(:trading_pair)
    end

    # Get all day trading positions approaching closure time
    def positions_approaching_closure
      Position.positions_approaching_closure.includes(:trading_pair)
    end

    # Close all day trading positions that need closure
    def close_expired_positions
      positions = positions_needing_closure
      return 0 if positions.empty?

      @logger.info("Closing #{positions.size} expired day trading positions")
      closed_count = 0

      positions.each do |position|
        closed_count += close_single_position(position)
      rescue => e
        @logger.error("Failed to close position #{position.id}: #{e.message}")
      end

      @logger.info("Successfully closed #{closed_count} expired day trading positions")
      closed_count
    end

    # Close positions that are approaching closure time (within 30 minutes of 24 hours)
    def close_approaching_positions
      positions = positions_approaching_closure
      return 0 if positions.empty?

      @logger.info("Closing #{positions.size} day trading positions approaching closure time")
      closed_count = 0

      positions.each do |position|
        closed_count += close_single_position(position, reason: "Approaching closure time")
      rescue => e
        @logger.error("Failed to close approaching position #{position.id}: #{e.message}")
      end

      @logger.info("Successfully closed #{closed_count} approaching day trading positions")
      closed_count
    end

    # Force close all open day trading positions (emergency closure)
    def force_close_all_day_trading_positions
      positions = Position.open_day_trading_positions
      return 0 if positions.empty?

      @logger.warn("Force closing all #{positions.size} day trading positions")
      closed_count = 0

      positions.each do |position|
        closed_count += close_single_position(position, reason: "Emergency closure")
      rescue => e
        @logger.error("Failed to force close position #{position.id}: #{e.message}")
      end

      @logger.warn("Force closed #{closed_count} day trading positions")
      closed_count
    end

    # Get current market prices for all open day trading positions
    def get_current_prices
      positions = Position.open_day_trading_positions
      return {} if positions.empty?

      prices = {}
      positions.each do |position|
        current_price = get_current_price_for_position(position)
        prices[position.id] = current_price if current_price
      rescue => e
        @logger.error("Failed to get price for position #{position.id}: #{e.message}")
      end

      prices
    end

    # Calculate total PnL for all open day trading positions
    def calculate_total_pnl
      positions = Position.open_day_trading_positions
      return 0 if positions.empty?

      current_prices = get_current_prices
      total_pnl = 0

      positions.each do |position|
        current_price = current_prices[position.id]
        next unless current_price

        pnl = position.calculate_pnl(current_price)
        total_pnl += pnl
      end

      total_pnl
    end

    # Get summary of day trading positions
    def get_position_summary
      open_positions = Position.open_day_trading_positions
      closed_today = Position.day_trading.closed.opened_today
      total_pnl = calculate_total_pnl

      {
        open_count: open_positions.count,
        closed_today_count: closed_today.count,
        total_open_value: open_positions.sum(:size),
        total_pnl: total_pnl,
        positions_needing_closure: positions_needing_closure.count,
        positions_approaching_closure: positions_approaching_closure.count
      }
    end

    # Check if any positions have hit take profit or stop loss
    def check_tp_sl_triggers
      positions = Position.open_day_trading_positions
      return [] if positions.empty?

      triggered_positions = []
      current_prices = get_current_prices

      positions.each do |position|
        current_price = current_prices[position.id]
        next unless current_price

        if position.hit_take_profit?(current_price)
          triggered_positions << {
            position: position,
            trigger: "take_profit",
            current_price: current_price,
            target_price: position.take_profit
          }
        elsif position.hit_stop_loss?(current_price)
          triggered_positions << {
            position: position,
            trigger: "stop_loss",
            current_price: current_price,
            target_price: position.stop_loss
          }
        end
      end

      triggered_positions
    end

    # Close positions that have hit take profit or stop loss
    def close_tp_sl_positions
      triggered_positions = check_tp_sl_triggers
      return 0 if triggered_positions.empty?

      @logger.info("Closing #{triggered_positions.size} positions that hit TP/SL")
      closed_count = 0

      triggered_positions.each do |trigger_info|
        position = trigger_info[:position]
        trigger = trigger_info[:trigger]
        current_price = trigger_info[:current_price]

        begin
          closed_count += close_single_position(position, reason: "#{trigger} triggered at #{current_price}")
        rescue => e
          @logger.error("Failed to close TP/SL position #{position.id}: #{e.message}")
        end
      end

      @logger.info("Successfully closed #{closed_count} TP/SL positions")
      closed_count
    end

    private

    def close_single_position(position, reason: "Day trading closure")
      @logger.info("Closing position #{position.id}: #{position.side} #{position.size} #{position.product_id} - #{reason}")

      # Get current market price for accurate PnL calculation
      current_price = get_current_price_for_position(position)
      return 0 unless current_price

      # Close the position in Coinbase
      begin
        result = @positions_service.close_position(
          product_id: position.product_id,
          size: position.size
        )

        if result["success"] || result["order_id"]
          # Update local position record
          position.force_close!(current_price, reason)
          @logger.info("Successfully closed position #{position.id} with PnL: #{position.pnl}")
          1
        else
          @logger.error("Failed to close position #{position.id} in Coinbase: #{result}")
          0
        end
      rescue => e
        @logger.error("Exception closing position #{position.id} in Coinbase: #{e.message}")
        # Still update local record to prevent infinite retry loops
        position.force_close!(current_price, "#{reason} (API error: #{e.message})")
        1
      end
    end

    def get_current_price_for_position(position)
      # Try to get current price from the most recent tick or candle
      # This is a simplified approach - in production you might want to use real-time market data

      # Try to get from recent ticks first
      recent_tick = Tick.where(product_id: position.product_id)
        .order(observed_at: :desc)
        .first

      if recent_tick && recent_tick.observed_at > 5.minutes.ago
        return recent_tick.price
      end

      # Fall back to most recent 1-minute candle
      recent_candle = Candle.for_symbol(position.product_id)
        .one_minute
        .order(timestamp: :desc)
        .first

      if recent_candle && recent_candle.timestamp > 5.minutes.ago
        return recent_candle.close
      end

      # If no recent data, use entry price as fallback
      @logger.warn("No recent price data for #{position.product_id}, using entry price")
      position.entry_price
    end
  end
end
