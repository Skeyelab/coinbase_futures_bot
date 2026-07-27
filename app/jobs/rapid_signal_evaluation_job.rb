# frozen_string_literal: true

class RapidSignalEvaluationJob < ApplicationJob
  queue_as :default

  # Minimum confidence to execute (issue #496).
  #
  # This was hardcoded at 75 — ABOVE the maximum the scorer has ever produced.
  # Across a year of BIP history the strategy emitted 311 signals with a maximum
  # confidence of 68.2 and a p99 of 63.6, so the trading path could not fire
  # under any market condition. 40 of the scorer's 100 points require a 5%
  # spread between the 1h EMA12 and EMA26, which on BTC essentially never
  # happens, so the scale never approaches its nominal ceiling.
  #
  # 30 is chosen from the measured joint distribution of confidence and realised
  # outcome, not from a trade count. Out-of-sample at 200/120 bps: >=0 gives
  # +11.36 bps/trade, >=30 gives +23.57 over 153 trades/yr, >=50 gives +59.02
  # over 37. >=30 is the point where per-trade edge and a sample large enough to
  # ever validate (#376 gate 2a wants 100/symbol) both hold.
  DEFAULT_MIN_CONFIDENCE = 30

  def self.min_confidence
    ENV.fetch("RSE_MIN_CONFIDENCE", DEFAULT_MIN_CONFIDENCE).to_f
  end

  def perform(product_id:, current_price:, asset:, day_trading: nil)
    @logger = Rails.logger
    @product_id = product_id
    @current_price = current_price.to_f
    @asset = asset
    @day_trading = day_trading.nil? ? Rails.application.config.default_day_trading : day_trading

    # Issue #480: one row per evaluation, whatever the outcome. Recording is
    # best-effort and never blocks an order.
    @decisions = Trading::DecisionRecorder.new(product_id: @product_id, asset: @asset, logger: @logger)

    if Trading::SymbolSuspension.suspended?(@product_id)
      @logger.info("[RSE] #{@product_id} is suspended (#{Trading::SymbolSuspension.all.dig(@product_id, "reason")}) — skipping evaluation")
      @decisions.rejected(:symbol_suspended)
      return
    end

    @logger.debug("[RSE] Evaluating rapid signals for #{@product_id} at $#{@current_price}")

    # Get current month contract for execution (also drives contract sizing)
    begin
      contract_manager = MarketData::FuturesContractManager.new(logger: @logger)
      target_contract = resolve_target_contract(contract_manager)
    rescue => e
      @logger.error("[RSE] Error getting futures contract: #{e.message}")
      return
    end

    unless target_contract
      @logger.warn("[RSE] No current month contract found for #{@asset}")
      @decisions.rejected(:no_contract)
      return
    end

    # Protection locks are keyed on the contract id (PositionLifecycle records
    # exits under position.product_id), so the entry gate needs it too.
    @target_contract = target_contract
    @decisions.contract_id = target_contract

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

    unless signal
      # The strategy's own reason, not an undifferentiated "no signal" — this is
      # what distinguishes an over-selective strategy from a data-starved one.
      @decisions.rejected(:strategy_no_signal, strategy_reason: strategy.try(:last_rejection)&.to_s)
      @logger.debug("[RSE] No actionable signal for #{@product_id}")
      return
    end

    if should_execute_signal?(signal)
      @logger.info("[RSE] Rapid signal generated for #{@product_id}: #{signal[:side]} #{signal[:quantity]} contracts")

      # Execute signal on futures contract
      execute_futures_signal(target_contract, signal)
    end
  rescue => e
    @logger.error("[RSE] Unexpected error in rapid signal evaluation: #{e.message}")
  end

  private

  # A tick that already names a tradeable contract IS the instrument to trade
  # (issue #484). Only a spot tick needs resolving to a dated contract by asset.
  # Without this a BIP tick resolved to the current-month BIT contract, so the
  # perp's feed drove an order on the dated future.
  def resolve_target_contract(contract_manager)
    return @product_id if Contract.tradeable_product?(@product_id)

    contract_manager.current_month_contract(@asset)
  end

  def should_execute_signal?(signal)
    return false unless signal

    # Only execute high-confidence signals (>75%) for rapid execution
    if signal[:confidence] < self.class.min_confidence
      @decisions&.rejected(:low_confidence, signal: signal, threshold: self.class.min_confidence)
      return false
    end

    # Protections (issue #479, ADR 0003). This job is the ONLY path that reaches
    # open_position — the realtime evaluator writes signal_alerts and places no
    # orders — so until now the entire #396-#401 protections epic wrote locks
    # that nothing on the trading path ever read. Cooldown, StoplossGuard and
    # MaxDrawdown bound the backtest and not production, which is a parity break
    # in the dangerous direction: the simulation was SAFER than live.
    #
    # Keyed on the contract id because that is what PositionLifecycle records
    # exits under, and on a normalized long/short because side matching is an
    # exact string compare — passing the raw "BUY" would silently miss a
    # side-scoped StoplossGuard lock.
    protection_side = SideNormalizer.position(signal[:side]).to_s.downcase
    if Trading::Protections.blocked?(symbol: @target_contract, side: protection_side)
      reason = Trading::Protections.block_reason(symbol: @target_contract, side: protection_side)
      @logger.info("[RSE] Skipping signal - protection active for #{@target_contract} (#{reason})")
      @decisions&.rejected(:protection_active, signal: signal, protection: reason)
      return false
    end

    # GLOBAL concurrent-position cap across ALL products. The per-asset cap below
    # does not bound total exposure — with many pairs enabled the bot could open
    # one position per asset and blow past the operator's intended 1-3 total. This
    # is the risk gate for trading a wider universe. Configurable via
    # MAX_CONCURRENT_POSITIONS (default 3).
    total_open = Position.open.count
    if total_open >= global_max_concurrent_positions
      @logger.info("[RSE] Skipping signal - at global max positions (#{total_open}/#{global_max_concurrent_positions})")
      @decisions&.rejected(:global_position_cap, signal: signal, open: total_open, cap: global_max_concurrent_positions)
      return false
    end

    # Check if we already have positions in this asset
    existing_positions = Position.open.by_asset(@asset).count
    max_positions = max_concurrent_positions_for_asset(@asset)

    if existing_positions >= max_positions
      @logger.info("[RSE] Skipping signal - already at max positions (#{existing_positions}/#{max_positions}) for #{@asset}")
      @decisions&.rejected(:asset_position_cap, signal: signal, open: existing_positions, cap: max_positions)
      return false
    end

    # Check if we have sufficient buying power
    unless sufficient_buying_power?(signal[:quantity])
      @decisions&.rejected(:insufficient_buying_power, signal: signal)
      return false
    end

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

    if order_succeeded?(result)
      @logger.info("[RSE] Successfully opened #{signal[:side]} position: #{signal[:quantity]} contracts of #{contract_id}")
      # No Position.create! here: open_position already persisted the record via
      # create_local_position_record, with the paper flag, the entry fee and a
      # linked Order row. Writing a second one would double-count every entry.
      @decisions&.traded(signal: signal, position_id: result["position_id"] || result[:position_id])
      send_position_alert("OPENED", contract_id, signal)
    else
      @logger.error("[RSE] Failed to open position: #{order_error(result)}")
      @decisions&.rejected(:order_failed, signal: signal, error: order_error(result))
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

  # Sizing knobs come from the per-asset registry (issue #340), not a hardcoded
  # BTC/ETH `case`. An unlisted asset (OIL, metals, any expansion pair) now
  # resolves to the conservative `default` block instead of silently inheriting
  # the crypto shape.
  def legacy_contract_size_for_asset(asset)
    Trading::AssetSizing.for(asset).contract_size_usd
  end

  def max_contracts_for_asset(asset)
    Trading::AssetSizing.for(asset).max_contracts
  end

  # Total open positions allowed across all products. Defaults to 3 (the top of
  # the operator's 1-3 range); override with MAX_CONCURRENT_POSITIONS.
  def global_max_concurrent_positions
    value = ENV.fetch("MAX_CONCURRENT_POSITIONS", "3").to_i
    value.positive? ? value : 3
  end

  def max_concurrent_positions_for_asset(asset)
    Trading::AssetSizing.for(asset).max_concurrent
  end

  # open_position returns the raw exchange (or dry-run) payload, which is
  # STRING keyed. This job used to test result[:success] — a symbol — which was
  # always nil, so every successful open was logged as a failure, no alert was
  # ever sent, and the branch that followed was dead code. Mirrors
  # open_position's own success test rather than inventing a second one.
  def order_succeeded?(result)
    return false unless result.is_a?(Hash)

    !!(result["success"] || result[:success] || result["order_id"] || result[:order_id])
  end

  def order_error(result)
    return "unknown error" unless result.is_a?(Hash)

    result["error"] || result[:error] || "unknown error"
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
