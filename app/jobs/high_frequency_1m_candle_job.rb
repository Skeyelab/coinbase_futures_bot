# frozen_string_literal: true

class HighFrequency1mCandleJob < ApplicationJob
  queue_as :high_frequency

  # Retry with exponential backoff, but fail fast for high-frequency operations
  retry_on StandardError, wait: :exponentially_longer, attempts: 3

  def perform
    @logger = Rails.logger
    @start_time = Time.current

    @logger.debug("[HF 1m Candles] Starting high-frequency 1-minute candle update")

    begin
      # Fetch and update 1-minute candles for active trading pairs
      update_1m_candles
      
      # Trigger signal generation if new candles are available
      trigger_signal_generation_if_needed
      
      # Log performance metrics
      log_performance_metrics
      
    rescue => e
      @logger.error("[HF 1m Candles] High-frequency 1m candle update failed: #{e.message}")
      @logger.error(e.backtrace.join("\n"))
      raise
    end
  end

  private

  def update_1m_candles
    rest = MarketData::CoinbaseRest.new
    
    TradingPair.enabled.find_each do |pair|
      begin
        # Get the last stored 1m candle timestamp
        last_candle = Candle.for_symbol(pair.product_id)
                           .where(timeframe: '1m')
                           .order(:timestamp)
                           .last

        # Calculate start time (last candle + 1 minute, or 5 minutes ago as fallback)
        start_time = if last_candle
                      last_candle.timestamp + 1.minute
                    else
                      5.minutes.ago
                    end

        # Only fetch if we need recent data (don't fetch if we're current)
        next if start_time > 1.minute.ago

        @logger.debug("[HF 1m Candles] Fetching 1m candles for #{pair.product_id} from #{start_time}")

        # Fetch 1-minute candles with minimal backfill
        new_candles_count = rest.upsert_1m_candles(
          product_id: pair.product_id,
          start_time: start_time,
          end_time: Time.current
        )

        if new_candles_count > 0
          @logger.info("[HF 1m Candles] Added #{new_candles_count} new 1m candles for #{pair.product_id}")
          
          # Mark that new data is available for signal generation
          @new_candle_data = true
        end

      rescue => e
        @logger.warn("[HF 1m Candles] Failed to update 1m candles for #{pair.product_id}: #{e.message}")
      end
    end
  end

  def trigger_signal_generation_if_needed
    # If new 1m candle data was added, trigger signal generation for intraday strategies
    return unless @new_candle_data

    @logger.info("[HF 1m Candles] New 1m candle data available, triggering signal generation")
    
    # Enqueue high-frequency signal generation job with higher priority
    HighFrequencySignalGenerationJob.set(priority: 1).perform_later
  end

  def log_performance_metrics
    execution_time = Time.current - @start_time
    
    # Log performance for monitoring
    @logger.info("[HF 1m Candles] Execution completed in #{(execution_time * 1000).round(2)}ms")
    
    # Alert if execution time is too high for high-frequency operations
    if execution_time > 10.seconds
      @logger.warn("[HF 1m Candles] Slow execution detected: #{execution_time.round(2)}s")
    end
    
    # Store performance metrics for dashboard monitoring
    performance_data = {
      job_name: 'high_frequency_1m_candle',
      execution_time_ms: (execution_time * 1000).round(2),
      timestamp: Time.current,
      new_data_available: @new_candle_data || false,
      memory_usage: get_memory_usage
    }
    
    # Log to structured format for metrics collection
    @logger.info("[HF 1m Candle Metrics] #{performance_data.to_json}")
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