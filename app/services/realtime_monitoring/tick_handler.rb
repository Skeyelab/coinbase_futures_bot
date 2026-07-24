# frozen_string_literal: true

module RealtimeMonitoring
  class TickHandler
    DEFAULT_BASIS_MONITOR_INTERVAL_SECONDS = 60
    DEFAULT_RAPID_SIGNAL_INTERVAL_SECONDS = 30
    MARKET_DATA_HEARTBEAT_INTERVAL_SECONDS = 5
    CLOSE_TRIGGER_COOLDOWN_SECONDS = 60

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
      beat_loop_heartbeats
      check_position_alerts(product_id, price)
      update_futures_monitoring(product_id, price) if spot_relevant?(product_id)
      evaluate_rapid_signals(product_id, price) if should_evaluate_signals?(product_id, price)
    end

    private

    # Beat the loop liveness heartbeats so a silently-dead feed/loop becomes
    # observable — the loop can't price positions without fresh ticks. Beats both
    # "market_data" (WS feed alive) and "realtime_signal": in a real_time:start
    # deployment this monitoring loop, not FuturesBotLauncher's signal-runner, is
    # what drives signal evaluation, so it must beat realtime_signal too or the
    # operator status shows a false "loop stale" alarm. Throttled in-memory (this
    # handler is a single long-lived instance) so a high tick rate doesn't turn
    # into a DB write per tick.
    def beat_loop_heartbeats(now = Time.current)
      return if @last_loop_beat_at &&
        now - @last_loop_beat_at < MARKET_DATA_HEARTBEAT_INTERVAL_SECONDS

      Heartbeat.beat!("market_data", now: now)
      Heartbeat.beat!("realtime_signal", now: now)
      @last_loop_beat_at = now
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

        # Liquidation buffer (issue #399): the highest-precedence safety exit —
        # close before the exchange liquidates, ahead of every other policy.
        next if check_liquidation_buffer_exit(position, price)

        # Dollar-PnL exit ($20-50 target + hard dollar stop) takes precedence for
        # day-trading positions; if it closes, skip the bps threshold checks.
        next if check_dollar_pnl_exit(position, price)

        # Time-decay take-profit (issue #398): book a stalled winner once the
        # age-decayed profit bar is met. An earlier take-profit only — never a stop.
        next if check_min_roi_exit(position, price)

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

    # Time-decay take-profit exit (issue #398). Closes when the position's
    # unrealized price return meets the age-decayed profit bar. Returns true if it
    # triggered a close. Inert unless a min_roi schedule is configured. Never a
    # stop — only an earlier take-profit, so it cannot widen risk.
    def check_min_roi_exit(position, current_price)
      policy = min_roi_policy(position.product_id)
      return false unless policy.enabled?

      reason = policy.exit_reason(
        profit_ratio: position.unrealized_profit_ratio(current_price),
        minutes_held: position.age_in_minutes
      )
      return false unless reason

      @logger.info("[RTM] time_decay_roi for #{position.product_id} at $#{current_price} " \
        "(#{(position.unrealized_profit_ratio(current_price) * 100).round(3)}% after #{position.age_in_minutes.to_i}m) — closing")
      trigger_position_close(position, reason.to_s)
      true
    end

    def min_roi_policy(symbol)
      (@min_roi_policies ||= {})[symbol] ||= Trading::MinimumRoiExit.from_config(symbol: symbol)
    end

    # Liquidation-buffer exit (issue #399). Closes a leveraged position once price
    # reaches the buffered pre-liquidation level. Highest-precedence safety exit;
    # surfaces a Slack warning because a near-liquidation event is notable.
    # Returns true if it triggered a close.
    def check_liquidation_buffer_exit(position, current_price)
      calc = liquidation_buffer(position.product_id)
      return false unless calc.enabled?
      return false unless calc.breached?(entry_price: position.entry_price,
        side: position.side, current_price: current_price)

      @logger.warn("[RTM] liquidation_buffer for #{position.product_id} #{position.side} " \
        "entry $#{position.entry_price} at $#{current_price} — closing before liquidation")
      trigger_position_close(position, "liquidation_buffer")
      SlackNotificationService.alert("warning", "Liquidation buffer exit",
        "Closed #{position.product_id} #{position.side} at $#{current_price} (entry $#{position.entry_price}) " \
        "before reaching liquidation.")
      true
    end

    def liquidation_buffer(symbol)
      (@liquidation_buffers ||= {})[symbol] ||= Trading::LiquidationBuffer.from_config(symbol: symbol)
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

    # Enqueue a close, debounced per position. A position that keeps meeting a
    # close condition every tick (e.g. an overdue day-trade past the 6h limit)
    # would otherwise enqueue a PositionCloseJob on every tick — ~85/min — flooding
    # the queue until a worker drains it (361 piled up in a paper session). The
    # in-memory cooldown (this handler is a single long-lived instance) re-triggers
    # at most once per cooldown per position, which still provides a retry backstop
    # if the position is somehow still open later.
    def trigger_position_close(position, reason, now: Time.current)
      @close_triggered_at ||= {}
      last = @close_triggered_at[position.id]
      return if last && now - last < CLOSE_TRIGGER_COOLDOWN_SECONDS

      @close_triggered_at[position.id] = now
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
      return false unless within_evaluation_hours?

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

    # Crypto futures trade 24/7, so signals are evaluated around the clock by
    # default. Set SIGNAL_EVAL_HOURS_ET to an inclusive ET hour window (e.g.
    # "9-16") to restrict evaluation to a session — for instruments that have one.
    def within_evaluation_hours?
      window = ENV["SIGNAL_EVAL_HOURS_ET"].to_s.strip
      return true if window.empty?

      from, to = window.split("-", 2).map(&:to_i)
      (from..to).cover?(Time.current.in_time_zone("America/New_York").hour)
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
