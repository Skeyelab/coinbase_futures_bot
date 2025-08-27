# frozen_string_literal: true

class RealTimeMonitoringJob < ApplicationJob
  queue_as :critical

  def perform(product_ids: ["BTC-USD", "ETH-USD"])
    @product_ids = Array(product_ids)
    @logger = Rails.logger
    @contract_manager = MarketData::FuturesContractManager.new(logger: @logger)

    @logger.info("[RTM] Starting real-time monitoring for #{@product_ids.join(", ")}")

    # Set up ticker callback for real-time processing
    on_ticker = proc do |ticker_data|
      process_real_time_tick(ticker_data)
    end

    # Start spot monitoring
    MarketData::CoinbaseSpotSubscriber.new(
      product_ids: @product_ids,
      logger: @logger,
      on_ticker: on_ticker
    ).start
  end

  private

  def process_real_time_tick(ticker_data)
    product_id = ticker_data["product_id"]
    price = ticker_data["price"]&.to_f
    timestamp = ticker_data["time"]

    return unless product_id && price && price > 0

    @logger.debug("[RTM] #{product_id}: $#{price} at #{timestamp}")

    # Store tick data for real-time analysis
    create_tick_record(product_id, price, timestamp)

    # Trigger position monitoring for day trading
    check_position_alerts(product_id, price)

    # Update futures contract monitoring for related assets
    update_futures_monitoring(product_id, price) if futures_relevant?(product_id)

    # Trigger rapid signal evaluation for day trading
    evaluate_rapid_signals(product_id, price) if should_evaluate_signals?(product_id, price)
  end

  def create_tick_record(product_id, price, timestamp)
    # Store recent ticks for rapid analysis
    Tick.create!(
      symbol: product_id,
      price: price,
      timestamp: parse_timestamp(timestamp),
      volume: 0 # Volume not provided in ticker feed
    )
  rescue => e
    @logger.warn("[RTM] Failed to store tick for #{product_id}: #{e.message}")
  end

  def check_position_alerts(product_id, price)
    asset = extract_asset_from_product_id(product_id)
    return unless asset

    # Check open positions for related futures contracts
    open_positions = Position.open.by_asset(asset)

    open_positions.each do |position|
      check_take_profit_stop_loss(position, price)
      check_day_trading_time_limits(position)
    end
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

    # Check if position has been open for more than 6 hours (day trading limit)
    if position.age_in_hours && position.age_in_hours > 6
      @logger.warn("[RTM] Day trading position #{position.product_id} exceeded 6-hour limit")
      trigger_position_close(position, "time_limit")
    end
  end

  def trigger_position_close(position, reason)
    # Enqueue immediate position closure
    PositionCloseJob.perform_later(
      position_id: position.id,
      reason: reason,
      priority: "immediate"
    )
  end

  def update_futures_monitoring(product_id, price)
    asset = extract_asset_from_product_id(product_id)
    return unless asset

    # Update basis monitoring for futures contracts
    current_month_contract = @contract_manager.current_month_contract(asset)
    upcoming_month_contract = @contract_manager.upcoming_month_contract(asset)

    [current_month_contract, upcoming_month_contract].compact.each do |contract_id|
      FuturesBasisMonitoringJob.perform_later(
        spot_product_id: product_id,
        futures_product_id: contract_id,
        spot_price: price
      )
    end
  end

  def evaluate_rapid_signals(product_id, price)
    # Check if we should evaluate 1-minute signals for day trading
    asset = extract_asset_from_product_id(product_id)
    return unless asset

    # Only evaluate signals every 30 seconds to avoid overload
    cache_key = "last_signal_eval_#{product_id}"
    last_eval = Rails.cache.read(cache_key)

    if !last_eval || (Time.current - last_eval) > 30.seconds
      Rails.cache.write(cache_key, Time.current, expires_in: 1.minute)

      RapidSignalEvaluationJob.perform_later(
        product_id: product_id,
        current_price: price,
        asset: asset
      )
    end
  end

  def should_evaluate_signals?(product_id, price)
    # Only evaluate signals during active trading hours (9 AM - 4 PM ET)
    current_hour_et = Time.current.in_time_zone("America/New_York").hour
    return false unless (9..16).cover?(current_hour_et)

    # Check if price movement is significant enough (>0.1% change in last minute)
    last_price_key = "last_price_#{product_id}"
    last_price = Rails.cache.read(last_price_key)

    if last_price
      price_change_pct = ((price - last_price) / last_price * 100).abs
      significant_movement = price_change_pct > 0.1
    else
      significant_movement = true # First price, consider it significant
    end

    Rails.cache.write(last_price_key, price, expires_in: 5.minutes)
    significant_movement
  end

  def futures_relevant?(product_id)
    ["BTC-USD", "ETH-USD"].include?(product_id)
  end

  def extract_asset_from_product_id(product_id)
    case product_id
    when "BTC-USD" then "BTC"
    when "ETH-USD" then "ETH"
    end
  end

  def parse_timestamp(timestamp_str)
    return Time.current unless timestamp_str

    Time.parse(timestamp_str)
  rescue
    Time.current
  end
end
