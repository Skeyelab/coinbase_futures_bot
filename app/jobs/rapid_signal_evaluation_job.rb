# frozen_string_literal: true

class RapidSignalEvaluationJob < ApplicationJob
  queue_as :default

  def perform(product_id:, current_price:, asset:, day_trading: nil)
    @logger = Rails.logger
    @product_id = product_id
    @current_price = current_price.to_f
    @asset = asset
    @day_trading = day_trading.nil? ? Rails.application.config.default_day_trading : day_trading

    @logger.debug("[RSE] Evaluating rapid signals for #{@product_id} at $#{@current_price}")

    # Use multi-timeframe strategy with emphasis on shorter timeframes for day trading
    strategy = Strategy::MultiTimeframeSignal.new(
      ema_1h_short: 21,
      ema_1h_long: 50,
      ema_15m: 21,
      ema_5m: 13,
      ema_1m: 8,
      min_1h_candles: 60,
      min_15m_candles: 80,
      min_5m_candles: 60,
      min_1m_candles: 30,
      tp_target: 0.004, # 40 bps for day trading
      sl_target: 0.003, # 30 bps for day trading
      contract_size_usd: contract_size_for_asset(@asset),
      max_position_size: max_contracts_for_asset(@asset),
      min_position_size: 1
    )

    # Get current month contract for execution
    begin
      contract_manager = MarketData::FuturesContractManager.new(logger: @logger)
      target_contract = contract_manager.current_month_contract(@asset)
    rescue => e
      @logger.error("[RSE] Error getting futures contract: #{e.message}")
      return
    end

    unless target_contract
      @logger.warn("[RSE] No current month contract found for #{@asset}")
      return
    end

    # Generate signal using spot price as reference
    begin
      equity_usd = TradingConfiguration.signal_equity_usd
      signal = strategy.signal(symbol: @product_id, equity_usd: equity_usd)
    rescue => e
      @logger.error("[RSE] Error generating signal: #{e.message}")
      return
    end

    if signal && should_execute_signal?(signal)
      @logger.info("[RSE] Rapid signal generated for #{@product_id}: #{signal[:side]} #{signal[:quantity]} contracts")

      # Execute signal on futures contract
      execute_futures_signal(target_contract, signal)
    else
      @logger.debug("[RSE] No actionable signal for #{@product_id}")
    end
  rescue => e
    @logger.error("[RSE] Unexpected error in rapid signal evaluation: #{e.message}")
  end

  private

  def should_execute_signal?(signal)
    return false unless signal

    # Only execute high-confidence signals (>75%) for rapid execution
    return false if signal[:confidence] < 75

    # Check if we already have positions in this asset
    existing_positions = Position.open.by_asset(@asset).count
    max_positions = max_concurrent_positions_for_asset(@asset)

    if existing_positions >= max_positions
      @logger.info("[RSE] Skipping signal - already at max positions (#{existing_positions}/#{max_positions}) for #{@asset}")
      return false
    end

    # Check if we have sufficient buying power
    return false unless sufficient_buying_power?(signal[:quantity])

    true
  end

  def execute_futures_signal(contract_id, signal)
    positions_service = Trading::CoinbasePositions.new(logger: @logger)

    # Execute the trade on the futures contract
    result = positions_service.open_position(
      product_id: contract_id,
      side: signal[:side],
      size: signal[:quantity],
      type: :market, # Use market orders for rapid execution
      day_trading: @day_trading,
      take_profit: signal[:tp],
      stop_loss: signal[:sl]
    )

    if result[:success]
      @logger.info("[RSE] Successfully opened #{signal[:side]} position: #{signal[:quantity]} contracts of #{contract_id}")

      # Create position tracking record
      Position.create!(
        product_id: contract_id,
        side: signal[:side],
        size: signal[:quantity],
        entry_price: signal[:price],
        entry_time: Time.current,
        status: "OPEN",
        day_trading: @day_trading,
        take_profit: signal[:tp],
        stop_loss: signal[:sl]
      )

      # Send alert
      send_position_alert("OPENED", contract_id, signal)
    else
      @logger.error("[RSE] Failed to open position: #{result[:error]}")
    end
  rescue => e
    @logger.error("[RSE] Error executing futures signal: #{e.message}")
  end

  def contract_size_for_asset(asset)
    case asset
    when "BTC" then 100.0  # $100 per BTC contract
    when "ETH" then 10.0   # $10 per ETH contract
    else 100.0
    end
  end

  def max_contracts_for_asset(asset)
    case asset
    when "BTC" then 5      # Max 5 BTC contracts (reduced from 10)
    when "ETH" then 10     # Max 10 ETH contracts (reduced from 20)
    else 5
    end
  end

  def max_concurrent_positions_for_asset(asset)
    case asset
    when "BTC" then 2      # Max 2 concurrent BTC positions (reduced from 3)
    when "ETH" then 3      # Max 3 concurrent ETH positions (reduced from 5)
    else 2
    end
  end

  def sufficient_buying_power?(quantity)
    # Simple check - in production this would check actual account balance
    # For now, assume we have sufficient buying power if quantity is reasonable
    quantity <= 10 # Max 10 contracts per signal (reduced from 20)
  end

  def send_position_alert(action, contract_id, signal)
    @logger.info("[ALERT] #{action}: #{signal[:side]} #{signal[:quantity]} contracts of #{contract_id} at $#{signal[:price]} (TP: $#{signal[:tp]}, SL: $#{signal[:sl]})")

    # In production, this could send Slack/Discord/email alerts
    # For now, just log the alert
  end
end
