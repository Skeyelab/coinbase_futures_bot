# frozen_string_literal: true

module RealtimeMonitoring
  class TickHandler
    DEFAULT_BASIS_MONITOR_INTERVAL_SECONDS = 60
    DEFAULT_RAPID_SIGNAL_INTERVAL_SECONDS = 30
    MARKET_DATA_HEARTBEAT_INTERVAL_SECONDS = 5

    def initialize(logger: Rails.logger, contract_manager: nil, phased_limiter: nil)
      @logger = logger
      @contract_manager = contract_manager || MarketData::FuturesContractManager.new(logger: logger)
      @phased_limiter = phased_limiter || PhasedRateLimiter.new
    end

    def process(ticker_data)
      product_id = ticker_data["product_id"]
      price = ticker_data["price"]&.to_f
      timestamp = ticker_data["time"]

      return unless product_id && price&.positive?

      @logger.debug("[RTM] #{product_id}: $#{price} at #{timestamp}")

      create_tick_record(product_id, price, timestamp)
      beat_market_data_heartbeat
      check_position_alerts(product_id, price)
      update_futures_monitoring(product_id, price) if spot_relevant?(product_id)
      evaluate_rapid_signals(product_id, price) if should_evaluate_signals?(product_id, price)
    end

    private

    # Beat the market-data liveness heartbeat so a silently-dead WebSocket feed
    # (dropped connection, no ticker messages) becomes observable — the loop
    # can't price positions without fresh ticks. Throttled in-memory (this
    # handler is a single long-lived instance shared by both subscribers) so a
    # high tick rate doesn't turn into a DB write per tick.
    def beat_market_data_heartbeat(now = Time.current)
      return if @last_market_data_beat_at &&
        now - @last_market_data_beat_at < MARKET_DATA_HEARTBEAT_INTERVAL_SECONDS

      Heartbeat.beat!("market_data", now: now)
      @last_market_data_beat_at = now
    end

    def create_tick_record(product_id, price, timestamp)
      Tick.create!(
        product_id: product_id,
        price: price,
        observed_at: parse_timestamp(timestamp)
      )
    rescue => e
      @logger.warn("[RTM] Failed to store tick for #{product_id}: #{e.message}")
    end

    def check_position_alerts(product_id, price)
      positions_for_tick(product_id).find_each do |position|
        # Record how far underwater this position went (MAE) before any exit
        # check, so the excursion is captured even on the tick that closes it.
        position.track_adverse_excursion!(price)

        # Dollar-PnL exit ($20-50 target + hard dollar stop) takes precedence for
        # day-trading positions; if it closes, skip the bps threshold checks.
        next if check_dollar_pnl_exit(position, price)

        check_take_profit_stop_loss(position, price)
        check_day_trading_time_limits(position)
      end
    end

    # Close a day-trading position on its unrealized dollar PnL: at the configured
    # profit target ($20-50) or the hard dollar stop-loss. Uses the contract-size-
    # aware Position#unrealized_pnl_at so the dollars are real (not a bps proxy).
    # Returns true if it triggered a close. Inert unless DOLLAR_*_USD is configured.
    def check_dollar_pnl_exit(position, current_price)
      return false unless position.day_trading?
      return false unless dollar_exit_policy.enabled?

      reason = dollar_exit_policy.exit_reason(position.unrealized_pnl_at(current_price))
      return false unless reason

      pnl = position.unrealized_pnl_at(current_price)
      @logger.info("[RTM] #{reason} for #{position.product_id} at $#{current_price} (unrealized $#{pnl.round(2)}) — closing")
      trigger_position_close(position, reason.to_s)
      true
    end

    def dollar_exit_policy
      @dollar_exit_policy ||= Trading::DollarExitPolicy.from_env
    end

    def positions_for_tick(product_id)
      if MarketData::RealtimeSubscriptionCatalog.futures_contract?(product_id)
        return Position.open.where(product_id: product_id)
      end

      asset = extract_asset_from_product_id(product_id)
      return Position.none unless asset

      prefix = MarketData::FuturesContractManager::ASSET_MAPPING[asset] || asset
      Position.open.by_asset(prefix)
    end

    def check_take_profit_stop_loss(position, current_price)
      return unless position.take_profit || position.stop_loss

      if position.long? && position.take_profit && current_price >= position.take_profit
        @logger.info("[RTM] Take profit hit for LONG position #{position.product_id} at $#{current_price}")
        trigger_position_close(position, "take_profit")
      elsif position.long? && position.stop_loss && current_price <= position.stop_loss
        @logger.info("[RTM] Stop loss hit for LONG position #{position.product_id} at $#{current_price}")
        trigger_position_close(position, "stop_loss")
      elsif position.short? && position.take_profit && current_price <= position.take_profit
        @logger.info("[RTM] Take profit hit for SHORT position #{position.product_id} at $#{current_price}")
        trigger_position_close(position, "take_profit")
      elsif position.short? && position.stop_loss && current_price >= position.stop_loss
        @logger.info("[RTM] Stop loss hit for SHORT position #{position.product_id} at $#{current_price}")
        trigger_position_close(position, "stop_loss")
      end
    end

    def check_day_trading_time_limits(position)
      return unless position.day_trading?

      if position.age_in_hours && position.age_in_hours > 6
        @logger.warn("[RTM] Day trading position #{position.product_id} exceeded 6-hour limit")
        trigger_position_close(position, "time_limit")
      end
    end

    def trigger_position_close(position, reason)
      PositionCloseJob.perform_later(
        position_id: position.id,
        reason: reason,
        priority: "immediate"
      )
    end

    def update_futures_monitoring(product_id, price)
      asset = extract_asset_from_product_id(product_id)
      return unless asset

      current_month_contract = @contract_manager.current_month_contract(asset)
      upcoming_month_contract = @contract_manager.upcoming_month_contract(asset)

      [current_month_contract, upcoming_month_contract].compact.each do |contract_id|
        next unless basis_monitor_due?(product_id, contract_id)

        FuturesBasisMonitoringJob.perform_later(
          spot_product_id: product_id,
          futures_product_id: contract_id,
          spot_price: price
        )
      end
    end

    def basis_monitor_due?(spot_product_id, futures_product_id)
      @phased_limiter.due?(
        key: "#{spot_product_id}:#{futures_product_id}",
        interval_seconds: basis_monitor_interval_seconds,
        cache_prefix: "futures_basis_monitor"
      )
    end

    def basis_monitor_interval_seconds
      seconds = ENV.fetch(
        "FUTURES_BASIS_MONITOR_INTERVAL_SECONDS",
        DEFAULT_BASIS_MONITOR_INTERVAL_SECONDS
      ).to_i
      seconds.positive? ? seconds : DEFAULT_BASIS_MONITOR_INTERVAL_SECONDS
    end

    def evaluate_rapid_signals(product_id, price)
      asset = extract_asset_from_product_id(product_id)
      return unless asset

      return unless @phased_limiter.due?(
        key: product_id,
        interval_seconds: rapid_signal_interval_seconds,
        cache_prefix: "last_signal_eval"
      )

      RapidSignalEvaluationJob.perform_later(
        product_id: product_id,
        current_price: price,
        asset: asset
      )
    end

    def should_evaluate_signals?(product_id, price)
      current_hour_et = Time.current.in_time_zone("America/New_York").hour
      return false unless (9..16).cover?(current_hour_et)

      last_price_key = "last_price_#{product_id}"
      last_price = Rails.cache.read(last_price_key)

      significant_movement = if last_price
        price_change_pct = ((price - last_price) / last_price * 100).abs
        price_change_pct > 0.1
      else
        true
      end

      Rails.cache.write(last_price_key, price, expires_in: 5.minutes)
      significant_movement
    end

    def rapid_signal_interval_seconds
      seconds = ENV.fetch(
        "RAPID_SIGNAL_INTERVAL_SECONDS",
        DEFAULT_RAPID_SIGNAL_INTERVAL_SECONDS
      ).to_i
      seconds.positive? ? seconds : DEFAULT_RAPID_SIGNAL_INTERVAL_SECONDS
    end

    def spot_relevant?(product_id)
      MarketData::RealtimeSubscriptionCatalog::KNOWN_SPOT_PRODUCT_IDS.include?(product_id)
    end

    def extract_asset_from_product_id(product_id)
      case product_id
      when "BTC-USD" then "BTC"
      when "ETH-USD" then "ETH"
      else
        Contract.parse_contract_info(product_id)&.dig(:base_currency)
      end
    end

    def parse_timestamp(timestamp_str)
      return Time.current unless timestamp_str

      Time.parse(timestamp_str)
    rescue
      Time.current
    end
  end
end
