# frozen_string_literal: true

class HighFrequencyPnLTrackingJob < ApplicationJob
  queue_as :high_frequency

  # Retry with exponential backoff, but fail fast for high-frequency operations
  retry_on StandardError, wait: :exponentially_longer, attempts: 3

  def perform
    @logger = Rails.logger
    @start_time = Time.current

    @logger.debug("[HF P&L Tracking] Starting high-frequency P&L tracking update")

    begin
      # Update real-time P&L for all open positions
      update_position_pnl
      
      # Calculate and store portfolio-level metrics
      update_portfolio_metrics
      
      # Check for P&L-based alerts and triggers
      check_pnl_alerts
      
      # Log performance metrics
      log_performance_metrics
      
    rescue => e
      @logger.error("[HF P&L Tracking] High-frequency P&L tracking failed: #{e.message}")
      @logger.error(e.backtrace.join("\n"))
      raise
    end
  end

  private

  def update_position_pnl
    open_positions = Position.open
    
    return if open_positions.empty?

    @logger.debug("[HF P&L Tracking] Updating P&L for #{open_positions.count} open positions")

    position_updates = []
    total_unrealized_pnl = 0

    open_positions.includes(:trading_pair).find_each do |position|
      begin
        # Get current market price
        current_price = get_current_price(position.product_id)
        next unless current_price

        # Calculate unrealized P&L
        unrealized_pnl = position.calculate_pnl(current_price)
        total_unrealized_pnl += unrealized_pnl

        # Store for batch update
        position_updates << {
          id: position.id,
          unrealized_pnl: unrealized_pnl,
          current_price: current_price,
          updated_at: Time.current
        }

        # Check for stop-loss or take-profit triggers
        if position.hit_stop_loss?(current_price)
          @logger.warn("[HF P&L Tracking] Stop loss triggered for position #{position.id} at $#{current_price}")
          trigger_position_closure(position, current_price, 'stop_loss')
        elsif position.hit_take_profit?(current_price)
          @logger.info("[HF P&L Tracking] Take profit triggered for position #{position.id} at $#{current_price}")
          trigger_position_closure(position, current_price, 'take_profit')
        end

      rescue => e
        @logger.warn("[HF P&L Tracking] Failed to update P&L for position #{position.id}: #{e.message}")
      end
    end

    # Batch update positions for better performance
    update_positions_batch(position_updates) if position_updates.any?

    @total_unrealized_pnl = total_unrealized_pnl
    @logger.debug("[HF P&L Tracking] Total unrealized P&L: $#{total_unrealized_pnl.round(2)}")
  end

  def update_portfolio_metrics
    # Calculate real-time portfolio metrics
    portfolio_metrics = {
      timestamp: Time.current,
      total_unrealized_pnl: @total_unrealized_pnl || 0,
      open_positions_count: Position.open.count,
      day_trading_positions_count: Position.open_day_trading_positions.count,
      total_equity: calculate_total_equity,
      daily_realized_pnl: calculate_daily_realized_pnl
    }

    # Store metrics for real-time monitoring
    Rails.cache.write('portfolio_metrics', portfolio_metrics, expires_in: 1.minute)
    
    @logger.debug("[HF P&L Tracking] Portfolio metrics updated: #{portfolio_metrics}")
  end

  def check_pnl_alerts
    # Check for significant P&L changes that require alerts
    return unless @total_unrealized_pnl

    # Get previous P&L from cache
    previous_metrics = Rails.cache.read('portfolio_metrics')
    return unless previous_metrics

    previous_pnl = previous_metrics[:total_unrealized_pnl] || 0
    pnl_change = @total_unrealized_pnl - previous_pnl
    pnl_change_percent = previous_pnl != 0 ? (pnl_change / previous_pnl.abs) * 100 : 0

    # Alert thresholds
    significant_change_threshold = 1000 # $1000
    percentage_change_threshold = 5    # 5%

    if pnl_change.abs > significant_change_threshold || pnl_change_percent.abs > percentage_change_threshold
      @logger.warn("[HF P&L Alert] Significant P&L change: $#{pnl_change.round(2)} (#{pnl_change_percent.round(2)}%)")
      
      # TODO: Implement alert notifications (Slack, email, etc.)
      # AlertService.send_pnl_alert(pnl_change, pnl_change_percent)
    end
  end

  def trigger_position_closure(position, current_price, reason)
    # Enqueue immediate position closure with high priority
    @logger.info("[HF P&L Tracking] Triggering position closure: #{position.id}, reason: #{reason}")
    
    # Use the day trading position manager for immediate closure
    manager = Trading::DayTradingPositionManager.new(logger: @logger)
    manager.close_position_immediately(position, current_price, reason)
  end

  def get_current_price(product_id)
    # Get cached current price from the high-frequency market data job
    trading_pair = TradingPair.find_by(product_id: product_id)
    return nil unless trading_pair

    # Use cached price if recent (within last minute)
    if trading_pair.last_price_updated_at && 
       trading_pair.last_price_updated_at > 1.minute.ago
      return trading_pair.last_price
    end

    # Fallback to REST API for current price
    begin
      rest = MarketData::CoinbaseRest.new
      ticker = rest.get_ticker(product_id)
      return BigDecimal(ticker['price']) if ticker && ticker['price']
    rescue => e
      @logger.warn("[HF P&L Tracking] Failed to get current price for #{product_id}: #{e.message}")
    end

    nil
  end

  def update_positions_batch(position_updates)
    # Use raw SQL for efficient batch updates
    return if position_updates.empty?

    values = position_updates.map do |update|
      "(#{update[:id]}, #{update[:unrealized_pnl]}, #{update[:current_price]}, '#{update[:updated_at].iso8601}')"
    end.join(', ')

    sql = <<~SQL
      UPDATE positions 
      SET 
        unrealized_pnl = updates.unrealized_pnl,
        current_price = updates.current_price,
        updated_at = updates.updated_at
      FROM (VALUES #{values}) AS updates(id, unrealized_pnl, current_price, updated_at)
      WHERE positions.id = updates.id::bigint
    SQL

    ActiveRecord::Base.connection.execute(sql)
    
    @logger.debug("[HF P&L Tracking] Batch updated #{position_updates.count} positions")
  end

  def calculate_total_equity
    # Calculate total equity including cash and unrealized P&L
    base_equity = 10_000 # TODO: Get from account service
    realized_pnl = Position.closed.sum(:pnl) || 0
    unrealized_pnl = @total_unrealized_pnl || 0
    
    base_equity + realized_pnl + unrealized_pnl
  end

  def calculate_daily_realized_pnl
    # Calculate today's realized P&L from closed positions
    Position.closed
            .where('close_time >= ?', Time.current.beginning_of_day)
            .sum(:pnl) || 0
  end

  def log_performance_metrics
    execution_time = Time.current - @start_time
    
    # Log performance for monitoring
    @logger.info("[HF P&L Tracking] Execution completed in #{(execution_time * 1000).round(2)}ms")
    
    # Alert if execution time is too high for high-frequency operations
    if execution_time > 3.seconds
      @logger.warn("[HF P&L Tracking] Slow execution detected: #{execution_time.round(2)}s")
    end
    
    # Store performance metrics for dashboard monitoring
    performance_data = {
      job_name: 'high_frequency_pnl_tracking',
      execution_time_ms: (execution_time * 1000).round(2),
      timestamp: Time.current,
      positions_processed: Position.open.count,
      total_unrealized_pnl: @total_unrealized_pnl || 0,
      memory_usage: get_memory_usage
    }
    
    # Log to structured format for metrics collection
    @logger.info("[HF P&L Tracking Metrics] #{performance_data.to_json}")
  end

  def get_memory_usage
    # Simple memory usage check (in MB)
    return 0 unless defined?(GC)
    
    begin
      gc_stats = GC.stat
      (gc_stats[:heap_allocated_pages] * gc_stats[:heap_page_size]) / (1024 * 1024)
    rescue
      0
    end
  end
end