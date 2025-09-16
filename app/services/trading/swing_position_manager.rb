# frozen_string_literal: true

module Trading
  # Manages swing trading positions with separate risk controls and lifecycle management
  # This service handles overnight/swing positions that are held for multiple days
  # with different risk parameters from day trading positions
  class SwingPositionManager
    include SentryServiceTracking

    def initialize(logger: Rails.logger)
      @logger = logger
      @positions_service = CoinbasePositions.new(logger: logger)
      @contract_manager = MarketData::FuturesContractManager.new(logger: logger)
      @config = Rails.application.config.swing_trading_config || default_config
    end

    # Position monitoring methods

    # Find positions close to contract expiry
    def positions_approaching_expiry
      swing_positions = Position.swing_trading.open.includes(:trading_pair)
      expiring_positions = []

      swing_positions.each do |position|
        next unless position.trading_pair&.expiration_date

        days_to_expiry = (position.trading_pair.expiration_date.to_date - Date.current).to_i
        if days_to_expiry <= @config[:expiry_buffer_days]
          expiring_positions << position
        end
      end

      expiring_positions
    end

    # Find positions held longer than max_hold_days
    def positions_exceeding_max_hold
      max_hold_time = @config[:max_hold_days].days.ago
      Position.swing_trading.open.where("entry_time < ?", max_hold_time).includes(:trading_pair)
    end

    # Risk management methods

    # Check take profit/stop loss for swing positions
    def check_swing_tp_sl_triggers
      positions = Position.swing_trading.open.includes(:trading_pair)
      return [] if positions.empty?

      triggered_positions = []

      positions.each do |position|
        current_price = get_current_price(position.product_id)
        next unless current_price

        if position.hit_take_profit?(current_price)
          triggered_positions << {position: position, trigger: "take_profit", current_price: current_price}
        elsif position.hit_stop_loss?(current_price)
          triggered_positions << {position: position, trigger: "stop_loss", current_price: current_price}
        end
      end

      triggered_positions
    end

    # Close positions before contract expiry
    def close_expiring_positions
      positions = positions_approaching_expiry
      return 0 if positions.empty?

      @logger.info("Closing #{positions.size} swing positions approaching contract expiry")
      closed_count = 0

      positions.each do |position|
        current_price = get_current_price(position.product_id)
        if current_price
          close_swing_position(position, current_price, "Contract expiry approaching")
          closed_count += 1
        else
          @logger.warn("Could not get current price for #{position.product_id}, skipping closure")
        end
      rescue => e
        @logger.error("Failed to close expiring position #{position.id}: #{e.message}")
      end

      @logger.info("Successfully closed #{closed_count} positions approaching expiry")
      closed_count
    end

    # Close positions that exceed maximum holding period
    def close_max_hold_positions
      positions = positions_exceeding_max_hold
      return 0 if positions.empty?

      @logger.info("Closing #{positions.size} swing positions exceeding max hold period")
      closed_count = 0

      positions.each do |position|
        current_price = get_current_price(position.product_id)
        if current_price
          close_swing_position(position, current_price, "Maximum holding period exceeded")
          closed_count += 1
        else
          @logger.warn("Could not get current price for #{position.product_id}, skipping closure")
        end
      rescue => e
        @logger.error("Failed to close max hold position #{position.id}: #{e.message}")
      end

      @logger.info("Successfully closed #{closed_count} positions exceeding max hold")
      closed_count
    end

    # Close positions that hit TP/SL
    def close_tp_sl_positions
      triggered_positions = check_swing_tp_sl_triggers
      return 0 if triggered_positions.empty?

      @logger.info("Closing #{triggered_positions.size} swing positions that hit TP/SL")
      closed_count = 0

      triggered_positions.each do |trigger_data|
        position = trigger_data[:position]
        trigger_type = trigger_data[:trigger]
        current_price = trigger_data[:current_price]

        begin
          close_swing_position(position, current_price, "#{trigger_type.humanize} triggered")
          closed_count += 1
        rescue => e
          @logger.error("Failed to close TP/SL position #{position.id}: #{e.message}")
        end
      end

      @logger.info("Successfully closed #{closed_count} positions via TP/SL")
      closed_count
    end

    # Position summary and monitoring

    # Get comprehensive summary of all swing positions
    def get_swing_position_summary
      positions = Position.swing_trading.open.includes(:trading_pair)

      summary = {
        total_positions: positions.count,
        total_exposure: 0.0,
        unrealized_pnl: 0.0,
        positions_by_asset: {},
        risk_metrics: {},
        positions: []
      }

      positions.each do |position|
        current_price = get_current_price(position.product_id)
        current_pnl = current_price ? position.calculate_pnl(current_price) : 0

        # Extract asset from product_id (e.g., "BTC-USD-PERP" -> "BTC")
        asset = position.product_id.split("-").first

        summary[:total_exposure] += position.size * (current_price || position.entry_price)
        summary[:unrealized_pnl] += current_pnl

        summary[:positions_by_asset][asset] ||= {count: 0, exposure: 0, pnl: 0}
        summary[:positions_by_asset][asset][:count] += 1
        summary[:positions_by_asset][asset][:exposure] += position.size * (current_price || position.entry_price)
        summary[:positions_by_asset][asset][:pnl] += current_pnl

        position_data = {
          id: position.id,
          product_id: position.product_id,
          side: position.side,
          size: position.size,
          entry_price: position.entry_price,
          current_price: current_price,
          entry_time: position.entry_time,
          duration_hours: position.age_in_hours&.round(2),
          unrealized_pnl: current_pnl,
          take_profit: position.take_profit,
          stop_loss: position.stop_loss,
          contract_expiry: position.trading_pair&.expiration_date,
          days_to_expiry: position.trading_pair&.expiration_date ? (position.trading_pair.expiration_date.to_date - Date.current).to_i : nil
        }

        summary[:positions] << position_data
      end

      # Calculate risk metrics
      summary[:risk_metrics] = calculate_swing_risk_metrics(summary)

      summary
    end

    # Get balance and margin information for swing trading
    def get_swing_balance_summary
      return {error: "Authentication required"} unless @positions_service.instance_variable_get(:@authenticated)

      begin
        # Get futures balance summary
        path = "/api/v3/brokerage/cfm/balance_summary"
        resp = @positions_service.send(:authenticated_get, path, {})
        balance_data = JSON.parse(resp.body)

        # Get margin window information
        margin_path = "/api/v3/brokerage/cfm/intraday_margin_setting"
        margin_resp = @positions_service.send(:authenticated_get, margin_path, {})
        margin_data = JSON.parse(margin_resp.body)

        {
          futures_buying_power: balance_data.dig("futures_buying_power")&.to_f || 0.0,
          total_usd_balance: balance_data.dig("total_usd_balance")&.to_f || 0.0,
          cfm_usd_balance: balance_data.dig("cfm_usd_balance")&.to_f || 0.0,
          unrealized_pnl: balance_data.dig("unrealized_pnl")&.to_f || 0.0,
          initial_margin: balance_data.dig("initial_margin")&.to_f || 0.0,
          available_margin: balance_data.dig("available_margin")&.to_f || 0.0,
          liquidation_threshold: balance_data.dig("liquidation_threshold")&.to_f || 0.0,
          liquidation_buffer_amount: balance_data.dig("liquidation_buffer_amount")&.to_f || 0.0,
          liquidation_buffer_percentage: balance_data.dig("liquidation_buffer_percentage")&.to_f || 0.0,
          margin_window: margin_data["margin_window"] || {},
          overnight_margin_enabled: margin_data["is_intraday_margin_killswitch_enabled"] == false
        }
      rescue => e
        @logger.error("Failed to get swing balance summary: #{e.message}")
        {error: "Failed to retrieve balance information: #{e.message}"}
      end
    end

    # Check if swing trading limits are within acceptable ranges
    def check_swing_risk_limits
      balance_summary = get_swing_balance_summary
      return {error: balance_summary[:error]} if balance_summary[:error]

      position_summary = get_swing_position_summary

      violations = []

      # Check maximum overnight exposure
      max_exposure = balance_summary[:total_usd_balance] * @config[:max_overnight_exposure]
      if position_summary[:total_exposure] > max_exposure
        violations << {
          type: "max_exposure_exceeded",
          current: position_summary[:total_exposure],
          limit: max_exposure,
          message: "Total swing position exposure exceeds #{(@config[:max_overnight_exposure] * 100).round(1)}% limit"
        }
      end

      # Check margin safety buffer
      available_margin = balance_summary[:available_margin]
      required_buffer = balance_summary[:total_usd_balance] * @config[:margin_safety_buffer]
      if available_margin < required_buffer
        violations << {
          type: "insufficient_margin_buffer",
          current: available_margin,
          required: required_buffer,
          message: "Available margin below #{(@config[:margin_safety_buffer] * 100).round(1)}% safety buffer"
        }
      end

      # Check leverage limits
      if balance_summary[:total_usd_balance] > 0
        current_leverage = position_summary[:total_exposure] / balance_summary[:total_usd_balance]
        if current_leverage > @config[:max_leverage_overnight]
          violations << {
            type: "excessive_leverage",
            current: current_leverage.round(2),
            limit: @config[:max_leverage_overnight],
            message: "Current leverage exceeds #{@config[:max_leverage_overnight]}x overnight limit"
          }
        end
      end

      {
        violations: violations,
        risk_status: violations.empty? ? "acceptable" : "violations_detected",
        total_exposure: position_summary[:total_exposure],
        available_margin: available_margin,
        leverage: (balance_summary[:total_usd_balance] > 0) ? (position_summary[:total_exposure] / balance_summary[:total_usd_balance]).round(2) : 0
      }
    end

    # Emergency closure of all swing positions
    def force_close_all_swing_positions(reason = "Emergency closure")
      positions = Position.swing_trading.open
      return 0 if positions.empty?

      @logger.warn("Force closing all #{positions.count} swing positions: #{reason}")
      closed_count = 0

      positions.each do |position|
        current_price = get_current_price(position.product_id)
        if current_price
          close_swing_position(position, current_price, reason)
        else
          # Force close even without current price using entry price
          position.force_close!(position.entry_price, reason)
        end
        closed_count += 1
      rescue => e
        @logger.error("Failed to force close swing position #{position.id}: #{e.message}")
      end

      @logger.warn("Force closed #{closed_count} swing positions")
      closed_count
    end

    private

    # Close a single swing position
    def close_swing_position(position, current_price, reason)
      @logger.info("Closing swing position #{position.id}: #{reason}")

      # Use Coinbase API to close the position
      result = @positions_service.close_position(
        product_id: position.product_id,
        size: position.size
      )

      if result && !result["error"]
        position.close_position!(current_price)
        @logger.info("Successfully closed swing position #{position.id} at #{current_price}")
      else
        error_msg = result&.dig("error") || "Unknown error"
        @logger.error("Failed to close swing position #{position.id} via API: #{error_msg}")
        raise "API closure failed: #{error_msg}"
      end
    end

    # Get current market price for a product
    def get_current_price(product_id)
      # Use API call to get current market price
      begin
        path = "/api/v3/brokerage/market/product_book"
        params = {product_id: product_id, limit: 1}
        resp = @positions_service.send(:authenticated_get, path, params)
        data = JSON.parse(resp.body)

        if data["pricebook"] && data["pricebook"]["bids"]&.any? && data["pricebook"]["asks"]&.any?
          bid = data["pricebook"]["bids"][0]["price"].to_f
          ask = data["pricebook"]["asks"][0]["price"].to_f
          return (bid + ask) / 2.0
        end
      rescue => e
        @logger.error("Failed to get current price for #{product_id}: #{e.message}")
      end

      nil
    end

    # Calculate risk metrics for swing positions
    def calculate_swing_risk_metrics(summary)
      return {} if summary[:total_positions] == 0

      metrics = {
        avg_position_size: summary[:total_exposure] / summary[:total_positions],
        largest_position: summary[:positions].map { |p| p[:size] * (p[:current_price] || p[:entry_price]) }.max || 0,
        avg_hold_time_hours: summary[:positions].map { |p| p[:duration_hours] || 0 }.sum / summary[:total_positions],
        positions_approaching_expiry: positions_approaching_expiry.count,
        positions_exceeding_max_hold: positions_exceeding_max_hold.count,
        tp_sl_triggered_positions: check_swing_tp_sl_triggers.count
      }

      # Asset concentration risk
      if summary[:positions_by_asset].any?
        max_asset_exposure = summary[:positions_by_asset].values.map { |data| data[:exposure] }.max
        metrics[:max_asset_concentration] = (summary[:total_exposure] > 0) ? (max_asset_exposure / summary[:total_exposure]) : 0
      end

      metrics
    end

    # Default configuration if not set in application config
    def default_config
      {
        max_hold_days: ENV.fetch("SWING_MAX_HOLD_DAYS", 5).to_i,
        expiry_buffer_days: ENV.fetch("SWING_EXPIRY_BUFFER_DAYS", 2).to_i,
        max_overnight_exposure: ENV.fetch("SWING_MAX_EXPOSURE", 0.3).to_f,
        enable_contract_roll: ENV.fetch("SWING_ENABLE_ROLL", false),
        margin_safety_buffer: ENV.fetch("SWING_MARGIN_BUFFER", 0.2).to_f,
        max_leverage_overnight: ENV.fetch("SWING_MAX_LEVERAGE", 3).to_i
      }
    end
  end
end
