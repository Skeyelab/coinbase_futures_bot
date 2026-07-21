# frozen_string_literal: true

class RapidSignalEvaluationJob < ApplicationJob
  queue_as :default

  def perform(product_id:, current_price:, asset:, day_trading: nil)
    @logger = Rails.logger
    @product_id = product_id
    @current_price = current_price.to_f
    @asset = asset
    @day_trading = day_trading.nil? ? Rails.application.config.default_day_trading : day_trading

    if Trading::SymbolSuspension.suspended?(@product_id)
      @logger.info("[RSE] #{@product_id} is suspended (#{Trading::SymbolSuspension.all.dig(@product_id, "reason")}) — skipping evaluation")
      return
    end

    @logger.debug("[RSE] Evaluating rapid signals for #{@product_id} at $#{@current_price}")

    # Get current month contract for execution (also drives contract sizing)
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

    # LIVE-configured strategy via the shared factory so calibrated per-symbol
    # tp/sl actually reach execution (this job previously hardcoded 40/30bps,
    # silently bypassing calibration). Rapid-path overrides: shorter min-candle
    # requirements for tick-driven evaluation, real contract notional (issue
    # #372: resolver base-units x current price, not hardcoded $100/$10).
    strategy = Trading::StrategyFactory.multi_timeframe(
      profile: TradingProfile.effective(symbol: @product_id),
      min_5m_candles: 60,
      min_1m_candles: 30,
      contract_size_usd: contract_notional_usd(target_contract),
      max_position_size: max_contracts_for_asset(@asset),
      min_position_size: 1
    )

    # Generate signal using spot price as reference
    begin
      equity_usd = Trading::SignalEquity.usd
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

    # GLOBAL concurrent-position cap across ALL products. The per-asset cap below
    # does not bound total exposure — with many pairs enabled the bot could open
    # one position per asset and blow past the operator's intended 1-3 total. This
    # is the risk gate for trading a wider universe. Configurable via
    # MAX_CONCURRENT_POSITIONS (default 3).
    total_open = Position.open.count
    if total_open >= global_max_concurrent_positions
      @logger.info("[RSE] Skipping signal - at global max positions (#{total_open}/#{global_max_concurrent_positions})")
      return false
    end

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
        side: SideNormalizer.position(signal[:side]),
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

  # Real $ notional per contract: resolver base-units x current price (issue
  # #372). The resolver returns DEFAULT (1) when the API lookup fails or is
  # unknown — fall back to the legacy per-asset assumption rather than treat
  # a whole coin as one contract.
  def contract_notional_usd(contract_id)
    contract_size = Trading::ContractSizeResolver.for_product(contract_id).to_f
    if (contract_size - Trading::ContractSizeResolver::DEFAULT_CONTRACT_SIZE.to_f).abs < Float::EPSILON
      return legacy_contract_size_for_asset(@asset)
    end

    (contract_size * @current_price).round(2)
  end

  def legacy_contract_size_for_asset(asset)
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

  # Total open positions allowed across all products. Defaults to 3 (the top of
  # the operator's 1-3 range); override with MAX_CONCURRENT_POSITIONS.
  def global_max_concurrent_positions
    value = ENV.fetch("MAX_CONCURRENT_POSITIONS", "3").to_i
    value.positive? ? value : 3
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
