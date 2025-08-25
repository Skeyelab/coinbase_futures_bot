# frozen_string_literal: true

class HighFrequencySignalGenerationJob < ApplicationJob
  queue_as :high_frequency

  # Retry with exponential backoff, but fail fast for high-frequency operations
  retry_on StandardError, wait: :exponentially_longer, attempts: 3

  def perform(equity_usd: nil)
    @logger = Rails.logger
    @start_time = Time.current

    @logger.debug("[HF Signal Generation] Starting high-frequency signal generation")

    begin
      @equity_usd = equity_usd || default_equity_usd
      
      # Generate signals using high-frequency 1m and 5m data
      generate_high_frequency_signals
      
      # Check for immediate entry opportunities
      check_immediate_entry_opportunities
      
      # Log performance metrics
      log_performance_metrics
      
    rescue => e
      @logger.error("[HF Signal Generation] High-frequency signal generation failed: #{e.message}")
      @logger.error(e.backtrace.join("\n"))
      raise
    end
  end

  private

  def generate_high_frequency_signals
    # Use a high-frequency strategy that analyzes 1m and 5m timeframes
    strategy = Strategy::HighFrequencyDayTrading.new(
      ema_1m_fast: 5,      # 5-period EMA on 1m charts
      ema_1m_slow: 13,     # 13-period EMA on 1m charts  
      ema_5m_trend: 21,    # 21-period EMA on 5m charts for trend
      min_1m_candles: 20,  # Minimum 1m candles needed
      min_5m_candles: 30   # Minimum 5m candles needed
    )

    signals_generated = 0
    
    TradingPair.enabled.find_each do |pair|
      begin
        @logger.debug("[HF Signal Generation] Analyzing #{pair.product_id} for high-frequency signals")
        
        # Generate signal using 1m and 5m data
        signal = strategy.signal(symbol: pair.product_id, equity_usd: @equity_usd)
        
        if signal
          @logger.info("[HF Signal Generation] #{pair.product_id} signal: #{signal[:side]} at $#{signal[:price].round(2)} qty=#{signal[:quantity]} conf=#{signal[:confidence]}%")
          
          # Store signal for potential execution
          store_high_frequency_signal(pair.product_id, signal)
          signals_generated += 1
          
          # Check if this is a high-confidence signal for immediate action
          if signal[:confidence] >= 85 && signal[:signal_type] == 'immediate'
            @logger.info("[HF Signal Generation] High-confidence immediate signal for #{pair.product_id}")
            trigger_immediate_execution_check(pair.product_id, signal)
          end
        else
          @logger.debug("[HF Signal Generation] #{pair.product_id} no high-frequency entry signal")
        end
        
      rescue => e
        @logger.warn("[HF Signal Generation] Failed to generate signal for #{pair.product_id}: #{e.message}")
      end
    end

    @signals_generated = signals_generated
    @logger.info("[HF Signal Generation] Generated #{signals_generated} high-frequency signals")
  end

  def check_immediate_entry_opportunities
    # Check for immediate entry opportunities based on:
    # 1. Price action patterns (breakouts, pullbacks)
    # 2. Volume spikes
    # 3. Momentum indicators
    
    TradingPair.enabled.find_each do |pair|
      begin
        # Get recent 1m candles for immediate analysis
        recent_1m_candles = Candle.for_symbol(pair.product_id)
                                  .where(timeframe: '1m')
                                  .order(:timestamp)
                                  .last(10)
        
        next if recent_1m_candles.size < 5

        # Check for breakout patterns
        breakout_signal = check_breakout_pattern(pair.product_id, recent_1m_candles)
        if breakout_signal
          @logger.info("[HF Signal Generation] Breakout pattern detected for #{pair.product_id}")
          store_immediate_opportunity(pair.product_id, breakout_signal)
        end

        # Check for volume spikes
        volume_signal = check_volume_spike(pair.product_id, recent_1m_candles)
        if volume_signal
          @logger.info("[HF Signal Generation] Volume spike detected for #{pair.product_id}")
          store_immediate_opportunity(pair.product_id, volume_signal)
        end

      rescue => e
        @logger.warn("[HF Signal Generation] Failed to check immediate opportunities for #{pair.product_id}: #{e.message}")
      end
    end
  end

  def check_breakout_pattern(product_id, candles)
    return nil if candles.size < 5

    # Simple breakout detection: current price breaking above recent highs
    recent_high = candles[-4..-2].map(&:high).max  # Exclude current and last candle
    current_price = candles.last.close
    
    # Breakout if current price is significantly above recent high
    if current_price > recent_high * 1.001  # 0.1% breakout threshold
      return {
        type: 'breakout',
        direction: 'long',
        entry_price: current_price,
        confidence: 75,
        timestamp: Time.current
      }
    end

    # Check for breakdown pattern
    recent_low = candles[-4..-2].map(&:low).min
    if current_price < recent_low * 0.999  # 0.1% breakdown threshold
      return {
        type: 'breakdown',
        direction: 'short',
        entry_price: current_price,
        confidence: 75,
        timestamp: Time.current
      }
    end

    nil
  end

  def check_volume_spike(product_id, candles)
    return nil if candles.size < 5

    # Calculate average volume over recent candles
    avg_volume = candles[-5..-2].map(&:volume).sum / 4.0
    current_volume = candles.last.volume

    # Volume spike if current volume is significantly higher
    if current_volume > avg_volume * 2.0  # 2x volume spike
      return {
        type: 'volume_spike',
        current_volume: current_volume,
        avg_volume: avg_volume,
        spike_ratio: current_volume / avg_volume,
        confidence: 65,
        timestamp: Time.current
      }
    end

    nil
  end

  def store_high_frequency_signal(product_id, signal)
    # Store signal in cache for potential execution
    cache_key = "hf_signal:#{product_id}"
    signal_data = signal.merge(
      generated_at: Time.current,
      expires_at: 5.minutes.from_now  # High-frequency signals expire quickly
    )
    
    Rails.cache.write(cache_key, signal_data, expires_in: 5.minutes)
    @logger.debug("[HF Signal Generation] Stored signal for #{product_id}")
  end

  def store_immediate_opportunity(product_id, opportunity)
    # Store immediate opportunity in cache with shorter expiry
    cache_key = "hf_opportunity:#{product_id}"
    opportunity_data = opportunity.merge(
      detected_at: Time.current,
      expires_at: 2.minutes.from_now  # Immediate opportunities expire very quickly
    )
    
    Rails.cache.write(cache_key, opportunity_data, expires_in: 2.minutes)
    @logger.debug("[HF Signal Generation] Stored immediate opportunity for #{product_id}")
  end

  def trigger_immediate_execution_check(product_id, signal)
    # Trigger a high-priority execution check for high-confidence signals
    @logger.info("[HF Signal Generation] Triggering immediate execution check for #{product_id}")
    
    # TODO: Integrate with futures execution system when available
    # For now, just log the signal for manual review or paper trading
    execution_data = {
      product_id: product_id,
      signal: signal,
      timestamp: Time.current,
      priority: 'immediate'
    }
    
    @logger.info("[HF Immediate Execution] #{execution_data.to_json}")
  end

  def default_equity_usd
    (ENV["HF_SIGNAL_EQUITY_USD"] || ENV["SIGNAL_EQUITY_USD"] || 10_000).to_f
  end

  def log_performance_metrics
    execution_time = Time.current - @start_time
    
    # Log performance for monitoring
    @logger.info("[HF Signal Generation] Execution completed in #{(execution_time * 1000).round(2)}ms")
    
    # Alert if execution time is too high for high-frequency operations
    if execution_time > 15.seconds
      @logger.warn("[HF Signal Generation] Slow execution detected: #{execution_time.round(2)}s")
    end
    
    # Store performance metrics for dashboard monitoring
    performance_data = {
      job_name: 'high_frequency_signal_generation',
      execution_time_ms: (execution_time * 1000).round(2),
      timestamp: Time.current,
      signals_generated: @signals_generated || 0,
      equity_usd: @equity_usd,
      memory_usage: get_memory_usage
    }
    
    # Log to structured format for metrics collection
    @logger.info("[HF Signal Generation Metrics] #{performance_data.to_json}")
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