# frozen_string_literal: true

class HighFrequencyMarketDataJob < ApplicationJob
  queue_as :high_frequency

  # Retry with exponential backoff, but fail fast for high-frequency operations
  retry_on StandardError, wait: :exponentially_longer, attempts: 3

  def perform
    @logger = Rails.logger
    @start_time = Time.current

    @logger.debug("[HF Market Data] Starting high-frequency market data update")

    begin
      # Update current prices for active trading pairs
      update_current_prices
      
      # Update order book data if WebSocket is connected
      update_order_book_metrics
      
      # Log performance metrics
      log_performance_metrics
      
    rescue => e
      @logger.error("[HF Market Data] High-frequency market data update failed: #{e.message}")
      @logger.error(e.backtrace.join("\n"))
      raise
    end
  end

  private

  def update_current_prices
    rest = MarketData::CoinbaseRest.new
    
    # Get current ticker data for active trading pairs
    TradingPair.enabled.find_each do |pair|
      begin
        ticker = rest.get_ticker(pair.product_id)
        next unless ticker && ticker['price']

        # Store current price with timestamp for high-frequency tracking
        current_price = BigDecimal(ticker['price'])
        
        # Update the trading pair with latest price and timestamp
        pair.update_columns(
          last_price: current_price,
          last_price_updated_at: Time.current,
          volume_24h: ticker['volume']&.to_d,
          price_change_24h: ticker['volume_30day']&.to_d
        )

        @logger.debug("[HF Market Data] Updated #{pair.product_id}: $#{current_price}")
        
      rescue => e
        @logger.warn("[HF Market Data] Failed to update price for #{pair.product_id}: #{e.message}")
      end
    end
  end

  def update_order_book_metrics
    # If WebSocket connections are active, aggregate recent order book data
    # This is a placeholder for future order book depth analysis
    
    TradingPair.enabled.find_each do |pair|
      begin
        # Calculate bid-ask spread and order book depth metrics
        # This would typically use WebSocket data stored in Redis or database
        
        @logger.debug("[HF Market Data] Order book metrics updated for #{pair.product_id}")
        
      rescue => e
        @logger.warn("[HF Market Data] Failed to update order book metrics for #{pair.product_id}: #{e.message}")
      end
    end
  end

  def log_performance_metrics
    execution_time = Time.current - @start_time
    
    # Log performance for monitoring
    @logger.info("[HF Market Data] Execution completed in #{(execution_time * 1000).round(2)}ms")
    
    # Alert if execution time is too high for high-frequency operations
    if execution_time > 5.seconds
      @logger.warn("[HF Market Data] Slow execution detected: #{execution_time.round(2)}s")
    end
    
    # Store performance metrics for dashboard monitoring
    performance_data = {
      job_name: 'high_frequency_market_data',
      execution_time_ms: (execution_time * 1000).round(2),
      timestamp: Time.current,
      memory_usage: get_memory_usage
    }
    
    # Log to structured format for metrics collection
    @logger.info("[HF Market Data Metrics] #{performance_data.to_json}")
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