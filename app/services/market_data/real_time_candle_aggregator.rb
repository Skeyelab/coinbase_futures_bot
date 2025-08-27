# frozen_string_literal: true

module MarketData
  # Real-time candle aggregator that updates OHLCV candles from live tick data
  # This service maintains candles for multiple timeframes (1m, 5m, 15m, 1h) in real-time
  # as ticks arrive from WebSocket connections
  class RealTimeCandleAggregator
    attr_reader :current_candles

    def initialize(logger: Rails.logger)
      @logger = logger
      @current_candles = {}
      @tick_buffer = Hash.new { |h, k| h[k] = [] }
      @last_tick_time = {}
    end

    # Process a new tick and update relevant candles
    def process_tick(tick_data)
      symbol = tick_data['product_id']
      price = tick_data['price'].to_f
      timestamp = parse_timestamp(tick_data['time'] || tick_data['ts'] || tick_data['timestamp'])

      return unless symbol && price && timestamp

      # Buffer ticks for processing
      @tick_buffer[symbol] << { price: price, timestamp: timestamp }

      # Process buffered ticks every 100ms or when buffer gets large
      process_buffered_ticks(symbol) if should_process_buffer?(symbol)

      update_candles_for_symbol(symbol, price, timestamp)
    end

    private

    def should_process_buffer?(symbol)
      buffer_size = @tick_buffer[symbol].size
      time_since_last = @last_tick_time[symbol] ? Time.current.to_f - @last_tick_time[symbol] : Float::INFINITY

      buffer_size >= 10 || time_since_last >= 0.1 # Process every 100ms or 10 ticks
    end

    def process_buffered_ticks(symbol)
      ticks = @tick_buffer[symbol]
      return if ticks.empty?

      # Sort ticks by timestamp and process in order
      sorted_ticks = ticks.sort_by { |t| t[:timestamp] }
      sorted_ticks.each do |tick|
        update_candles_for_symbol(symbol, tick[:price], tick[:timestamp])
      end

      @tick_buffer[symbol].clear
      @last_tick_time[symbol] = Time.current.to_f
    end

    def update_candles_for_symbol(symbol, price, timestamp)
      timeframes.each do |timeframe, interval|
        update_candle(symbol, timeframe, interval, price, timestamp)
      end
    end

    def update_candle(symbol, timeframe, interval_seconds, price, timestamp)
      candle_key = "#{symbol}:#{timeframe}"

      # Calculate the candle period start time
      period_start = calculate_period_start(timestamp, interval_seconds)

      # Get or create current candle
      candle = @current_candles[candle_key] ||= {
        symbol: symbol,
        timeframe: timeframe,
        timestamp: period_start,
        open: price,
        high: price,
        low: price,
        close: price,
        volume: 0,
        tick_count: 0
      }

      # Check if we've moved to a new period
      if candle[:timestamp] != period_start
        # Save the completed candle
        save_completed_candle(candle)

        # Start new candle
        @current_candles[candle_key] = {
          symbol: symbol,
          timeframe: timeframe,
          timestamp: period_start,
          open: price,
          high: price,
          low: price,
          close: price,
          volume: 0,
          tick_count: 0
        }
        candle = @current_candles[candle_key]
      end

      # Update candle with new price
      candle[:high] = [candle[:high], price].max
      candle[:low] = [candle[:low], price].min
      candle[:close] = price
      candle[:tick_count] += 1
    end

    def save_completed_candle(candle_data)
      return unless candle_data[:tick_count] > 0

      Candle.upsert({
                      symbol: candle_data[:symbol],
                      timeframe: candle_data[:timeframe],
                      timestamp: candle_data[:timestamp],
                      open: candle_data[:open],
                      high: candle_data[:high],
                      low: candle_data[:low],
                      close: candle_data[:close],
                      volume: candle_data[:volume]
                    }, unique_by: :index_candles_on_symbol_and_timeframe_and_timestamp)

      @logger.debug("[RTC] Saved #{candle_data[:symbol]} #{candle_data[:timeframe]} candle at #{candle_data[:timestamp]}: O:#{candle_data[:open]} H:#{candle_data[:high]} L:#{candle_data[:low]} C:#{candle_data[:close]}")
    end

    def calculate_period_start(timestamp, interval_seconds)
      # Round down to the nearest interval boundary
      Time.at((timestamp.to_i / interval_seconds) * interval_seconds).utc
    end

    def parse_timestamp(time_value)
      case time_value
      when String
        Time.parse(time_value).utc
      when Numeric
        Time.at(time_value).utc
      when Time
        time_value.utc
      else
        Time.current.utc
      end
    rescue StandardError => e
      @logger.warn("[RTC] Failed to parse timestamp #{time_value}: #{e.message}")
      Time.current.utc
    end

    def timeframes
      {
        '1m' => 60,
        '5m' => 300,
        '15m' => 900,
        '1h' => 3600
      }
    end
  end
end
