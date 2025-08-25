# frozen_string_literal: true

class RealTimePnLService
  attr_reader :logger

  def initialize(logger: Rails.logger)
    @logger = logger
  end

  # Calculate real-time P&L for a specific position
  def calculate_position_pnl(position, current_price = nil)
    return 0 unless position&.open?

    current_price ||= get_current_price(position.product_id)
    return 0 unless current_price

    position.calculate_pnl(current_price)
  end

  # Calculate total portfolio P&L metrics
  def calculate_portfolio_metrics
    start_time = Time.current

    open_positions = Position.open.includes(:trading_pair)
    
    metrics = {
      timestamp: Time.current,
      open_positions_count: open_positions.count,
      day_trading_positions_count: 0,
      total_unrealized_pnl: 0,
      total_exposure: 0,
      daily_realized_pnl: calculate_daily_realized_pnl,
      positions_by_side: { long: 0, short: 0 },
      positions_by_status: {},
      average_position_age: 0,
      risk_metrics: {}
    }

    position_ages = []
    unrealized_pnl_by_position = []

    open_positions.find_each do |position|
      begin
        # Get current price for position
        current_price = get_current_price(position.product_id)
        next unless current_price

        # Calculate position metrics
        unrealized_pnl = calculate_position_pnl(position, current_price)
        position_value = (position.size * current_price).abs
        
        metrics[:total_unrealized_pnl] += unrealized_pnl
        metrics[:total_exposure] += position_value
        
        # Track position details
        metrics[:day_trading_positions_count] += 1 if position.day_trading?
        metrics[:positions_by_side][position.side.downcase.to_sym] += 1
        
        # Position age tracking
        if position.entry_time
          age_hours = (Time.current - position.entry_time) / 1.hour
          position_ages << age_hours
        end

        # P&L distribution
        unrealized_pnl_by_position << unrealized_pnl

        # Update position cache with current data
        update_position_cache(position, current_price, unrealized_pnl)

      rescue => e
        @logger.warn("[Real-Time P&L] Failed to process position #{position.id}: #{e.message}")
      end
    end

    # Calculate derived metrics
    metrics[:average_position_age] = position_ages.any? ? position_ages.sum / position_ages.size : 0
    metrics[:risk_metrics] = calculate_risk_metrics(unrealized_pnl_by_position, metrics[:total_exposure])
    metrics[:total_equity] = calculate_total_equity(metrics[:total_unrealized_pnl], metrics[:daily_realized_pnl])

    # Performance tracking
    execution_time = Time.current - start_time
    metrics[:calculation_time_ms] = (execution_time * 1000).round(2)

    @logger.debug("[Real-Time P&L] Portfolio metrics calculated in #{metrics[:calculation_time_ms]}ms")

    metrics
  end

  # Get real-time P&L for all open positions
  def get_real_time_position_pnl
    start_time = Time.current
    position_pnl = {}

    Position.open.find_each do |position|
      begin
        current_price = get_current_price(position.product_id)
        next unless current_price

        pnl = calculate_position_pnl(position, current_price)
        position_pnl[position.id] = {
          position_id: position.id,
          product_id: position.product_id,
          side: position.side,
          entry_price: position.entry_price,
          current_price: current_price,
          unrealized_pnl: pnl,
          pnl_percentage: position.entry_price ? (pnl / (position.size * position.entry_price).abs) * 100 : 0,
          age_hours: position.age_in_hours,
          size: position.size
        }

      rescue => e
        @logger.warn("[Real-Time P&L] Failed to calculate P&L for position #{position.id}: #{e.message}")
      end
    end

    execution_time = Time.current - start_time
    @logger.debug("[Real-Time P&L] Position P&L calculated for #{position_pnl.size} positions in #{(execution_time * 1000).round(2)}ms")

    position_pnl
  end

  # Check for positions that have hit stop-loss or take-profit levels
  def check_tp_sl_triggers
    triggered_positions = []

    Position.open.find_each do |position|
      begin
        current_price = get_current_price(position.product_id)
        next unless current_price

        if position.hit_stop_loss?(current_price)
          triggered_positions << {
            position: position,
            trigger_type: 'stop_loss',
            current_price: current_price,
            trigger_price: position.stop_loss,
            unrealized_pnl: calculate_position_pnl(position, current_price)
          }
        elsif position.hit_take_profit?(current_price)
          triggered_positions << {
            position: position,
            trigger_type: 'take_profit',
            current_price: current_price,
            trigger_price: position.take_profit,
            unrealized_pnl: calculate_position_pnl(position, current_price)
          }
        end

      rescue => e
        @logger.warn("[Real-Time P&L] Failed to check TP/SL for position #{position.id}: #{e.message}")
      end
    end

    if triggered_positions.any?
      @logger.info("[Real-Time P&L] Found #{triggered_positions.size} positions with triggered TP/SL")
    end

    triggered_positions
  end

  # Calculate P&L change rate (for alerting on rapid changes)
  def calculate_pnl_change_rate(window_minutes: 5)
    current_metrics = Rails.cache.read('portfolio_metrics')
    return 0 unless current_metrics

    # Get historical metrics from cache
    cache_key = "portfolio_metrics_#{window_minutes}m_ago"
    historical_metrics = Rails.cache.read(cache_key)
    
    # Store current metrics for future comparison
    Rails.cache.write(cache_key, current_metrics, expires_in: window_minutes.minutes + 1.minute)
    
    return 0 unless historical_metrics

    current_pnl = current_metrics[:total_unrealized_pnl] || 0
    historical_pnl = historical_metrics[:total_unrealized_pnl] || 0
    
    # Calculate change rate ($ per minute)
    time_diff_minutes = window_minutes
    pnl_change = current_pnl - historical_pnl
    
    change_rate = time_diff_minutes > 0 ? pnl_change / time_diff_minutes : 0

    {
      change_rate_per_minute: change_rate,
      total_change: pnl_change,
      window_minutes: window_minutes,
      current_pnl: current_pnl,
      historical_pnl: historical_pnl
    }
  end

  private

  def get_current_price(product_id)
    # Try to get cached price first (from high-frequency market data job)
    trading_pair = TradingPair.find_by(product_id: product_id)
    
    if trading_pair&.last_price && 
       trading_pair.last_price_updated_at && 
       trading_pair.last_price_updated_at > 2.minutes.ago
      return trading_pair.last_price
    end

    # Fallback to REST API (avoid this in high-frequency operations)
    begin
      rest = MarketData::CoinbaseRest.new
      ticker = rest.get_ticker(product_id)
      return BigDecimal(ticker['price']) if ticker&.dig('price')
    rescue => e
      @logger.warn("[Real-Time P&L] Failed to get current price for #{product_id}: #{e.message}")
    end

    nil
  end

  def calculate_daily_realized_pnl
    Position.closed
            .where('close_time >= ?', Time.current.beginning_of_day)
            .sum(:pnl) || 0
  end

  def calculate_risk_metrics(pnl_values, total_exposure)
    return {} if pnl_values.empty?

    positive_pnl = pnl_values.select { |pnl| pnl > 0 }
    negative_pnl = pnl_values.select { |pnl| pnl < 0 }

    {
      winning_positions: positive_pnl.size,
      losing_positions: negative_pnl.size,
      win_rate: pnl_values.size > 0 ? (positive_pnl.size.to_f / pnl_values.size * 100).round(2) : 0,
      average_win: positive_pnl.any? ? (positive_pnl.sum / positive_pnl.size).round(2) : 0,
      average_loss: negative_pnl.any? ? (negative_pnl.sum / negative_pnl.size).round(2) : 0,
      largest_win: positive_pnl.any? ? positive_pnl.max.round(2) : 0,
      largest_loss: negative_pnl.any? ? negative_pnl.min.round(2) : 0,
      risk_reward_ratio: calculate_risk_reward_ratio(positive_pnl, negative_pnl),
      portfolio_risk_percentage: total_exposure > 0 ? (negative_pnl.sum.abs / total_exposure * 100).round(2) : 0
    }
  end

  def calculate_risk_reward_ratio(positive_pnl, negative_pnl)
    return 0 if negative_pnl.empty? || positive_pnl.empty?

    avg_win = positive_pnl.sum / positive_pnl.size
    avg_loss = negative_pnl.sum.abs / negative_pnl.size

    avg_loss > 0 ? (avg_win / avg_loss).round(2) : 0
  end

  def calculate_total_equity(unrealized_pnl, daily_realized_pnl)
    # Base equity (this should come from account service in production)
    base_equity = ENV.fetch('BASE_EQUITY_USD', 10_000).to_f
    
    # Total realized P&L (all time)
    total_realized_pnl = Position.closed.sum(:pnl) || 0
    
    base_equity + total_realized_pnl + unrealized_pnl
  end

  def update_position_cache(position, current_price, unrealized_pnl)
    # Cache position data for high-frequency access
    cache_key = "position_pnl:#{position.id}"
    cache_data = {
      position_id: position.id,
      current_price: current_price,
      unrealized_pnl: unrealized_pnl,
      updated_at: Time.current
    }
    
    Rails.cache.write(cache_key, cache_data, expires_in: 1.minute)
  end
end