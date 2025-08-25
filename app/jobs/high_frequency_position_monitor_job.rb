# frozen_string_literal: true

class HighFrequencyPositionMonitorJob < ApplicationJob
  queue_as :high_frequency

  # Retry with exponential backoff, but fail fast for high-frequency operations
  retry_on StandardError, wait: :exponentially_longer, attempts: 3

  def perform
    @logger = Rails.logger
    @start_time = Time.current

    @logger.debug("[HF Position Monitor] Starting high-frequency position monitoring")

    begin
      # Monitor day trading position time limits
      monitor_day_trading_time_limits
      
      # Check position risk metrics
      monitor_position_risk_metrics
      
      # Monitor for stale positions or data
      monitor_stale_positions
      
      # Log performance metrics
      log_performance_metrics
      
    rescue => e
      @logger.error("[HF Position Monitor] High-frequency position monitoring failed: #{e.message}")
      @logger.error(e.backtrace.join("\n"))
      raise
    end
  end

  private

  def monitor_day_trading_time_limits
    # Check positions approaching day trading time limits
    positions_approaching_limit = Position.day_trading
                                         .open
                                         .where('entry_time < ?', 22.hours.ago) # 2 hours before 24h limit

    if positions_approaching_limit.any?
      @logger.warn("[HF Position Monitor] #{positions_approaching_limit.count} positions approaching day trading time limit")
      
      positions_approaching_limit.find_each do |position|
        hours_open = position.age_in_hours
        @logger.warn("[HF Position Monitor] Position #{position.id} open for #{hours_open.round(2)} hours")
        
        # Alert if position is very close to limit (23+ hours)
        if hours_open >= 23
          @logger.error("[HF Position Monitor] URGENT: Position #{position.id} needs immediate closure - open for #{hours_open.round(2)} hours")
          
          # Trigger immediate closure
          trigger_emergency_position_closure(position, 'time_limit_emergency')
        elsif hours_open >= 22
          @logger.warn("[HF Position Monitor] Position #{position.id} approaching closure time - open for #{hours_open.round(2)} hours")
          
          # Trigger warning alert
          trigger_position_warning(position, 'approaching_time_limit')
        end
      end
    end

    # Check for positions that should have been closed yesterday
    overnight_positions = Position.day_trading.open.opened_yesterday
    
    if overnight_positions.any?
      @logger.error("[HF Position Monitor] CRITICAL: #{overnight_positions.count} day trading positions held overnight!")
      
      overnight_positions.find_each do |position|
        @logger.error("[HF Position Monitor] CRITICAL: Position #{position.id} held overnight - immediate closure required")
        trigger_emergency_position_closure(position, 'overnight_hold_violation')
      end
    end
  end

  def monitor_position_risk_metrics
    open_positions = Position.open
    return if open_positions.empty?

    total_exposure = 0
    high_risk_positions = []

    open_positions.find_each do |position|
      begin
        # Calculate position exposure
        current_price = get_current_price(position.product_id)
        next unless current_price

        position_value = position.size * current_price
        total_exposure += position_value.abs

        # Check for high-risk positions (large unrealized losses)
        unrealized_pnl = position.calculate_pnl(current_price)
        pnl_percentage = (unrealized_pnl / position_value.abs) * 100

        # Flag positions with >5% unrealized loss
        if pnl_percentage < -5
          high_risk_positions << {
            position: position,
            pnl_percentage: pnl_percentage,
            unrealized_pnl: unrealized_pnl
          }
        end

      rescue => e
        @logger.warn("[HF Position Monitor] Failed to calculate risk for position #{position.id}: #{e.message}")
      end
    end

    # Log total exposure
    @logger.debug("[HF Position Monitor] Total portfolio exposure: $#{total_exposure.round(2)}")

    # Alert on high-risk positions
    if high_risk_positions.any?
      @logger.warn("[HF Position Monitor] #{high_risk_positions.count} high-risk positions detected")
      
      high_risk_positions.each do |risk_data|
        position = risk_data[:position]
        pnl_pct = risk_data[:pnl_percentage]
        unrealized_pnl = risk_data[:unrealized_pnl]
        
        @logger.warn("[HF Position Monitor] High-risk position #{position.id}: #{pnl_pct.round(2)}% loss ($#{unrealized_pnl.round(2)})")
        
        # Trigger risk alert if loss is severe (>10%)
        if pnl_pct < -10
          trigger_position_warning(position, 'high_risk_loss')
        end
      end
    end

    @total_exposure = total_exposure
    @high_risk_count = high_risk_positions.count
  end

  def monitor_stale_positions
    # Check for positions with stale price data
    stale_threshold = 2.minutes.ago
    
    open_positions_with_stale_data = Position.open
                                           .joins(:trading_pair)
                                           .where('trading_pairs.last_price_updated_at < ? OR trading_pairs.last_price_updated_at IS NULL', 
                                                 stale_threshold)

    if open_positions_with_stale_data.any?
      @logger.warn("[HF Position Monitor] #{open_positions_with_stale_data.count} positions have stale price data")
      
      # Trigger price data refresh
      HighFrequencyMarketDataJob.set(priority: 1).perform_later
    end

    # Check for positions with missing critical data
    positions_missing_data = Position.open.where(
      'entry_price IS NULL OR product_id IS NULL OR size IS NULL'
    )

    if positions_missing_data.any?
      @logger.error("[HF Position Monitor] CRITICAL: #{positions_missing_data.count} positions have missing critical data")
      
      positions_missing_data.find_each do |position|
        @logger.error("[HF Position Monitor] Position #{position.id} missing data - needs manual review")
      end
    end
  end

  def trigger_emergency_position_closure(position, reason)
    @logger.error("[HF Position Monitor] Triggering emergency closure for position #{position.id}: #{reason}")
    
    begin
      # Get current price for closure
      current_price = get_current_price(position.product_id)
      
      if current_price
        # Use the day trading position manager for immediate closure
        manager = Trading::DayTradingPositionManager.new(logger: @logger)
        manager.close_position_immediately(position, current_price, reason)
      else
        @logger.error("[HF Position Monitor] Cannot close position #{position.id} - no current price available")
        # TODO: Implement manual intervention alert
      end
      
    rescue => e
      @logger.error("[HF Position Monitor] Failed to trigger emergency closure for position #{position.id}: #{e.message}")
    end
  end

  def trigger_position_warning(position, warning_type)
    @logger.warn("[HF Position Monitor] Position warning for #{position.id}: #{warning_type}")
    
    # TODO: Implement alerting system (Slack, email, dashboard notifications)
    warning_data = {
      position_id: position.id,
      warning_type: warning_type,
      timestamp: Time.current,
      position_age_hours: position.age_in_hours,
      product_id: position.product_id
    }
    
    # Log structured warning for alerting systems
    @logger.warn("[HF Position Warning] #{warning_data.to_json}")
  end

  def get_current_price(product_id)
    # Get cached current price from the high-frequency market data job
    trading_pair = TradingPair.find_by(product_id: product_id)
    return nil unless trading_pair

    # Use cached price if recent (within last 2 minutes for monitoring)
    if trading_pair.last_price_updated_at && 
       trading_pair.last_price_updated_at > 2.minutes.ago
      return trading_pair.last_price
    end

    # Return nil to indicate stale data - don't fetch here to avoid API limits
    nil
  end

  def log_performance_metrics
    execution_time = Time.current - @start_time
    
    # Log performance for monitoring
    @logger.info("[HF Position Monitor] Execution completed in #{(execution_time * 1000).round(2)}ms")
    
    # Alert if execution time is too high for high-frequency operations
    if execution_time > 5.seconds
      @logger.warn("[HF Position Monitor] Slow execution detected: #{execution_time.round(2)}s")
    end
    
    # Store performance metrics for dashboard monitoring
    performance_data = {
      job_name: 'high_frequency_position_monitor',
      execution_time_ms: (execution_time * 1000).round(2),
      timestamp: Time.current,
      open_positions_count: Position.open.count,
      day_trading_positions_count: Position.open_day_trading_positions.count,
      total_exposure: @total_exposure || 0,
      high_risk_positions: @high_risk_count || 0,
      memory_usage: get_memory_usage
    }
    
    # Log to structured format for metrics collection
    @logger.info("[HF Position Monitor Metrics] #{performance_data.to_json}")
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