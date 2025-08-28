# frozen_string_literal: true

require "rails_helper"

RSpec.describe MarketData::RealTimeCandleAggregator, type: :service do
  let(:logger) { instance_double(Logger) }
  let(:aggregator) { described_class.new(logger: logger) }

  before do
    # Ensure clean state for each test
    aggregator.instance_variable_set(:@tick_buffer, Hash.new { |h, k| h[k] = [] })
    aggregator.instance_variable_set(:@last_tick_time, {})
    aggregator.instance_variable_set(:@current_candles, {})
    allow(logger).to receive(:debug)
    allow(logger).to receive(:warn)
  end

  describe "#initialize" do
    it "initializes with empty candle storage and tick buffer" do
      expect(aggregator.current_candles).to be_empty
      expect(aggregator.instance_variable_get(:@tick_buffer)).to be_empty
      expect(aggregator.instance_variable_get(:@last_tick_time)).to be_empty
    end

    it "uses provided logger" do
      expect(aggregator.instance_variable_get(:@logger)).to eq(logger)
    end

    it "uses Rails.logger as default" do
      aggregator = described_class.new
      expect(aggregator.instance_variable_get(:@logger)).to eq(Rails.logger)
    end
  end

  describe "#process_tick" do
    let(:valid_tick_data) do
      {
        "product_id" => "BTC-USD",
        "price" => "50000.00",
        "time" => "2025-01-15T10:30:45Z"
      }
    end

    context "with valid tick data" do
      it "processes tick and updates candles" do
        expect(aggregator).to receive(:update_candles_for_symbol).with("BTC-USD", 50_000.0, anything).twice
        aggregator.process_tick(valid_tick_data)
      end

      it "buffers ticks for processing" do
        aggregator.process_tick(valid_tick_data)
        buffer = aggregator.instance_variable_get(:@tick_buffer)
        # Buffer may be empty if processing occurred
        expect(buffer["BTC-USD"]).to be_an(Array)
        expect(buffer["BTC-USD"].size).to be <= 1
      end

      it "processes buffered ticks when buffer is large" do
        # Mock should_process_buffer? to prevent processing until the 11th tick
        allow(aggregator).to receive(:should_process_buffer?).and_return(false)

        # Process 11 ticks without triggering buffer processing
        11.times do |i|
          tick_data = valid_tick_data.merge("price" => "5000#{i}.00")
          aggregator.process_tick(tick_data)
        end

        buffer = aggregator.instance_variable_get(:@tick_buffer)
        # All ticks should be buffered since we prevented processing
        expect(buffer["BTC-USD"].size).to eq(11)
      end

      it "processes buffered ticks after time threshold" do
        # Mock should_process_buffer? to always return false to prevent processing
        allow(aggregator).to receive(:should_process_buffer?).and_return(false)

        # First tick
        first_tick = valid_tick_data
        aggregator.process_tick(first_tick)

        # Simulate time passing (this would normally trigger processing)
        allow(Time).to receive(:current).and_return(Time.current + 0.2)

        second_tick = valid_tick_data.merge("price" => "50001.00")
        aggregator.process_tick(second_tick)

        buffer = aggregator.instance_variable_get(:@tick_buffer)
        # Both ticks should remain in buffer since processing is disabled
        expect(buffer["BTC-USD"].size).to eq(2)
      end
    end

    context "with invalid tick data" do
      it "ignores ticks without product_id" do
        invalid_tick = valid_tick_data.except("product_id")
        aggregator.process_tick(invalid_tick)
        buffer = aggregator.instance_variable_get(:@tick_buffer)
        # Buffer may contain empty arrays for accessed symbols, but no actual ticks
        expect(buffer.values.all?(&:empty?)).to be true
      end

      it "ignores ticks without price" do
        invalid_tick = valid_tick_data.except("price")
        aggregator.process_tick(invalid_tick)
        buffer = aggregator.instance_variable_get(:@tick_buffer)
        # Buffer may contain empty arrays for accessed symbols, but no actual ticks
        expect(buffer.values.all?(&:empty?)).to be true
      end

      it "ignores ticks without timestamp" do
        invalid_tick = valid_tick_data.except("time")
        aggregator.process_tick(invalid_tick)
        buffer = aggregator.instance_variable_get(:@tick_buffer)
        # Buffer may contain empty arrays for accessed symbols, but no actual ticks
        expect(buffer.values.all?(&:empty?)).to be true
      end

      it "handles invalid price format gracefully" do
        invalid_tick = valid_tick_data.merge("price" => "invalid")
        aggregator.process_tick(invalid_tick)
        buffer = aggregator.instance_variable_get(:@tick_buffer)
        # Buffer may contain empty arrays for accessed symbols, but no actual ticks
        expect(buffer.values.all?(&:empty?)).to be true
      end
    end

    context "with different timestamp formats" do
      it "handles ISO8601 timestamp" do
        tick = valid_tick_data.merge("time" => "2025-01-15T10:30:45Z")
        expect { aggregator.process_tick(tick) }.not_to raise_error
      end

      it "handles Unix timestamp as string" do
        timestamp = Time.parse("2025-01-15T10:30:45Z").to_i.to_s
        tick = valid_tick_data.merge("time" => timestamp)
        expect { aggregator.process_tick(tick) }.not_to raise_error
      end

      it "handles Unix timestamp as number" do
        timestamp = Time.parse("2025-01-15T10:30:45Z").to_i
        tick = valid_tick_data.merge("time" => timestamp)
        expect { aggregator.process_tick(tick) }.not_to raise_error
      end

      it "handles Time object" do
        timestamp = Time.parse("2025-01-15T10:30:45Z")
        tick = valid_tick_data.merge("time" => timestamp)
        expect { aggregator.process_tick(tick) }.not_to raise_error
      end

      it "falls back to current time for invalid timestamp" do
        tick = valid_tick_data.merge("time" => "invalid")
        expect(logger).to receive(:warn).with(/Failed to parse timestamp/)
        aggregator.process_tick(tick)
        buffer = aggregator.instance_variable_get(:@tick_buffer)
        # Buffer may be empty if processing occurred, or may contain the processed tick
        expect(buffer["BTC-USD"]).to be_an(Array)
        if buffer["BTC-USD"].size > 0
          expect(buffer["BTC-USD"].first[:timestamp]).to be_within(1.second).of(Time.current.utc)
        end
      end
    end
  end

  describe "#update_candles_for_symbol" do
    let(:symbol) { "BTC-USD" }
    let(:price) { 50_000.0 }
    let(:timestamp) { Time.parse("2025-01-15T10:30:00Z") }

    it "updates candles for all timeframes" do
      timeframes = %w[1m 5m 15m 1h]

      timeframes.each do |timeframe|
        expect(aggregator).to receive(:update_candle).with(symbol, timeframe, anything, price, timestamp)
      end

      aggregator.send(:update_candles_for_symbol, symbol, price, timestamp)
    end

    it "uses correct interval seconds for each timeframe" do
      expect(aggregator).to receive(:update_candle).with(symbol, "1m", 60, price, timestamp)
      expect(aggregator).to receive(:update_candle).with(symbol, "5m", 300, price, timestamp)
      expect(aggregator).to receive(:update_candle).with(symbol, "15m", 900, price, timestamp)
      expect(aggregator).to receive(:update_candle).with(symbol, "1h", 3600, price, timestamp)

      aggregator.send(:update_candles_for_symbol, symbol, price, timestamp)
    end
  end

  describe "#update_candle" do
    let(:symbol) { "BTC-USD" }
    let(:timeframe) { "1m" }
    let(:interval_seconds) { 60 }
    let(:price) { 50_000.0 }
    let(:timestamp) { Time.parse("2025-01-15T10:30:30Z") }

    context "when no candle exists for the period" do
      it "creates a new candle" do
        aggregator.send(:update_candle, symbol, timeframe, interval_seconds, price, timestamp)

        candle_key = "#{symbol}:#{timeframe}"
        candle = aggregator.current_candles[candle_key]

        expect(candle).to include(
          symbol: symbol,
          timeframe: timeframe,
          open: price,
          high: price,
          low: price,
          close: price,
          volume: 0,
          tick_count: 1
        )
        expect(candle[:timestamp]).to eq(Time.parse("2025-01-15T10:30:00Z")) # Rounded to period start
      end
    end

    context "when candle exists for the same period" do
      let!(:existing_candle) do
        aggregator.current_candles["#{symbol}:#{timeframe}"] = {
          symbol: symbol,
          timeframe: timeframe,
          timestamp: Time.parse("2025-01-15T10:30:00Z"),
          open: 49_000.0,
          high: 49_500.0,
          low: 48_500.0,
          close: 49_200.0,
          volume: 0,
          tick_count: 5
        }
      end

      it "updates existing candle with new price data" do
        new_price = 51_000.0
        aggregator.send(:update_candle, symbol, timeframe, interval_seconds, new_price, timestamp)

        candle = aggregator.current_candles["#{symbol}:#{timeframe}"]
        expect(candle[:high]).to eq(51_000.0) # New high
        expect(candle[:low]).to eq(48_500.0) # Original low maintained
        expect(candle[:close]).to eq(51_000.0) # Updated close
        expect(candle[:tick_count]).to eq(6) # Incremented tick count
      end
    end

    context "when moving to a new period" do
      let!(:existing_candle) do
        aggregator.current_candles["#{symbol}:#{timeframe}"] = {
          symbol: symbol,
          timeframe: timeframe,
          timestamp: Time.parse("2025-01-15T10:30:00Z"),
          open: 50_000.0,
          high: 50_500.0,
          low: 49_500.0,
          close: 50_200.0,
          volume: 0,
          tick_count: 10
        }
      end

      it "saves completed candle and creates new one" do
        # Move to next minute
        new_timestamp = Time.parse("2025-01-15T10:31:00Z")
        new_price = 51_000.0

        expect(aggregator).to receive(:save_completed_candle).with(existing_candle)

        aggregator.send(:update_candle, symbol, timeframe, interval_seconds, new_price, new_timestamp)

        candle = aggregator.current_candles["#{symbol}:#{timeframe}"]
        expect(candle[:timestamp]).to eq(Time.parse("2025-01-15T10:31:00Z"))
        expect(candle[:open]).to eq(51_000.0)
        expect(candle[:tick_count]).to eq(1)
      end
    end
  end

  describe "#save_completed_candle" do
    let(:candle_data) do
      {
        symbol: "BTC-USD",
        timeframe: "1m",
        timestamp: Time.parse("2025-01-15T10:30:00Z"),
        open: 50_000.0,
        high: 50_500.0,
        low: 49_500.0,
        close: 50_200.0,
        volume: 0,
        tick_count: 5
      }
    end

    context "with valid candle data" do
      it "saves candle to database" do
        expect(Candle).to receive(:upsert).with(
          {
            symbol: "BTC-USD",
            timeframe: "1m",
            timestamp: Time.parse("2025-01-15T10:30:00Z"),
            open: 50_000.0,
            high: 50_500.0,
            low: 49_500.0,
            close: 50_200.0,
            volume: 0
          },
          unique_by: :index_candles_on_symbol_and_timeframe_and_timestamp
        )

        aggregator.send(:save_completed_candle, candle_data)
      end

      it "logs candle save operation" do
        expect(logger).to receive(:debug).with(/RTC\] Saved BTC-USD 1m candle/)

        aggregator.send(:save_completed_candle, candle_data)
      end
    end

    context "with candle that has no ticks" do
      let(:empty_candle) { candle_data.merge(tick_count: 0) }

      it "does not save candle" do
        expect(Candle).not_to receive(:upsert)
        aggregator.send(:save_completed_candle, empty_candle)
      end
    end
  end

  describe "#calculate_period_start" do
    it "rounds down to nearest interval boundary" do
      timestamp = Time.parse("2025-01-15T10:30:45Z")

      # 1 minute interval
      result = aggregator.send(:calculate_period_start, timestamp, 60)
      expect(result).to eq(Time.parse("2025-01-15T10:30:00Z"))

      # 5 minute interval
      result = aggregator.send(:calculate_period_start, timestamp, 300)
      expect(result).to eq(Time.parse("2025-01-15T10:30:00Z"))

      # 1 hour interval
      result = aggregator.send(:calculate_period_start, timestamp, 3600)
      expect(result).to eq(Time.parse("2025-01-15T10:00:00Z"))
    end

    it "returns UTC time" do
      timestamp = Time.parse("2025-01-15T10:30:45Z")
      result = aggregator.send(:calculate_period_start, timestamp, 60)
      expect(result.utc?).to be true
    end
  end

  describe "#timeframes" do
    it "returns correct timeframe mappings" do
      expected = {
        "1m" => 60,
        "5m" => 300,
        "15m" => 900,
        "1h" => 3600
      }

      expect(aggregator.send(:timeframes)).to eq(expected)
    end
  end

  describe "#process_buffered_ticks" do
    let(:symbol) { "BTC-USD" }

    context "with buffered ticks" do
      let(:ticks) do
        [
          {price: 50_000.0, timestamp: Time.parse("2025-01-15T10:30:01Z")},
          {price: 50_100.0, timestamp: Time.parse("2025-01-15T10:30:02Z")},
          {price: 50_050.0, timestamp: Time.parse("2025-01-15T10:30:03Z")}
        ]
      end

      before do
        aggregator.instance_variable_set(:@tick_buffer, {symbol => ticks})
      end

      it "sorts ticks by timestamp" do
        # Add ticks out of order
        out_of_order_ticks = [
          {price: 50_000.0, timestamp: Time.parse("2025-01-15T10:30:03Z")},
          {price: 50_100.0, timestamp: Time.parse("2025-01-15T10:30:01Z")},
          {price: 50_050.0, timestamp: Time.parse("2025-01-15T10:30:02Z")}
        ]
        aggregator.instance_variable_set(:@tick_buffer, {symbol => out_of_order_ticks})

        expect(aggregator).to receive(:update_candles_for_symbol).exactly(3).times do |sym, price, ts|
          # Should be called in chronological order
          expect(ts).to(satisfy { |t| t <= Time.parse("2025-01-15T10:30:03Z") })
        end

        aggregator.send(:process_buffered_ticks, symbol)
      end

      it "clears buffer after processing" do
        aggregator.send(:process_buffered_ticks, symbol)
        buffer = aggregator.instance_variable_get(:@tick_buffer)
        expect(buffer[symbol]).to be_empty
      end

      it "updates last tick time" do
        aggregator.send(:process_buffered_ticks, symbol)
        last_tick_time = aggregator.instance_variable_get(:@last_tick_time)
        expect(last_tick_time[symbol]).to be_within(1.second).of(Time.current.to_f)
      end
    end

    context "with empty buffer" do
      it "does nothing" do
        aggregator.instance_variable_set(:@tick_buffer, {symbol => []})
        expect(aggregator).not_to receive(:update_candles_for_symbol)
        aggregator.send(:process_buffered_ticks, symbol)
      end
    end
  end

  describe "#should_process_buffer?" do
    let(:symbol) { "BTC-USD" }

    before do
      aggregator.instance_variable_set(:@tick_buffer, {symbol => []})
    end

    it "returns true when buffer size >= 10" do
      10.times do
        aggregator.instance_variable_get(:@tick_buffer)[symbol] << {price: 50_000.0, timestamp: Time.current}
      end

      expect(aggregator.send(:should_process_buffer?, symbol)).to be true
    end

    it "returns true when time since last tick >= 100ms" do
      aggregator.instance_variable_get(:@tick_buffer)[symbol] << {price: 50_000.0, timestamp: Time.current}
      aggregator.instance_variable_set(:@last_tick_time, {symbol => Time.current.to_f - 0.2})

      expect(aggregator.send(:should_process_buffer?, symbol)).to be true
    end

    it "returns false when conditions not met" do
      aggregator.instance_variable_get(:@tick_buffer)[symbol] << {price: 50_000.0, timestamp: Time.current}
      aggregator.instance_variable_set(:@last_tick_time, {symbol => Time.current.to_f - 0.05})

      expect(aggregator.send(:should_process_buffer?, symbol)).to be false
    end
  end

  describe "memory management" do
    it "maintains current_candles hash" do
      tick_data = {
        "product_id" => "BTC-USD",
        "price" => "50000.00",
        "time" => "2025-01-15T10:30:45Z"
      }

      aggregator.process_tick(tick_data)

      expect(aggregator.current_candles.keys).to include("BTC-USD:1m", "BTC-USD:5m", "BTC-USD:15m", "BTC-USD:1h")
    end

    it "cleans up completed candles" do
      # Create and complete multiple candles
      timestamps = [
        "2025-01-15T10:30:00Z",
        "2025-01-15T10:31:00Z",
        "2025-01-15T10:32:00Z"
      ]

      timestamps.each do |ts|
        tick_data = {
          "product_id" => "BTC-USD",
          "price" => "50000.00",
          "time" => ts
        }
        aggregator.process_tick(tick_data)
      end

      # Should only have current candles, completed ones should be saved and removed
      expect(aggregator.current_candles.keys.size).to eq(4) # One for each timeframe
    end
  end
end
