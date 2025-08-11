# frozen_string_literal: true

require "test_helper"

class CandleTest < ActiveSupport::TestCase
  def setup
    # Clean up any existing data
    Candle.destroy_all
    TradingPair.destroy_all

    @valid_candle = Candle.new(
      symbol: "BTC-USD",
      timeframe: "1h",
      timestamp: Time.now.utc,
      open: 50000.0,
      high: 51000.0,
      low: 49000.0,
      close: 50500.0,
      volume: 100.5
    )
  end

  def teardown
    Candle.destroy_all
    TradingPair.destroy_all
  end

  def test_valid_candle
    assert @valid_candle.valid?
  end

  def test_requires_symbol
    @valid_candle.symbol = nil
    assert_not @valid_candle.valid?
    assert_includes @valid_candle.errors[:symbol], "can't be blank"
  end

  def test_requires_timestamp
    @valid_candle.timestamp = nil
    assert_not @valid_candle.valid?
    assert_includes @valid_candle.errors[:timestamp], "can't be blank"
  end

  def test_timeframe_validation
    # Test valid timeframes
    %w[15m 1h 6h 1d].each do |timeframe|
      @valid_candle.timeframe = timeframe
      assert @valid_candle.valid?, "#{timeframe} should be valid"
    end

    # Test invalid timeframes
    %w[30m 2h 12h invalid].each do |timeframe|
      @valid_candle.timeframe = timeframe
      assert_not @valid_candle.valid?, "#{timeframe} should be invalid"
      assert_includes @valid_candle.errors[:timeframe], "is not included in the list"
    end
  end

  def test_uniqueness_constraint
    # Save the first candle
    @valid_candle.save!

    # Try to create another with same symbol, timeframe, and timestamp
    duplicate = Candle.new(
      symbol: @valid_candle.symbol,
      timeframe: @valid_candle.timeframe,
      timestamp: @valid_candle.timestamp,
      open: 60000.0,
      high: 61000.0,
      low: 59000.0,
      close: 60500.0,
      volume: 200.0
    )

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:timestamp], "has already been taken"
  end

  def test_for_symbol_scope
    @valid_candle.save!

    # Create another candle with different symbol
    eth_candle = Candle.create!(
      symbol: "ETH-USD",
      timeframe: "1h",
      timestamp: Time.now.utc,
      open: 3000.0,
      high: 3100.0,
      low: 2900.0,
      close: 3050.0,
      volume: 50.0
    )

    btc_candles = Candle.for_symbol("BTC-USD")
    assert_equal 1, btc_candles.count
    assert_equal "BTC-USD", btc_candles.first.symbol
  end

  def test_hourly_scope
    @valid_candle.save!

    # Create a 15m candle
    candle_15m = Candle.create!(
      symbol: "BTC-USD",
      timeframe: "15m",
      timestamp: Time.now.utc,
      open: 50000.0,
      high: 51000.0,
      low: 49000.0,
      close: 50500.0,
      volume: 100.5
    )

    hourly_candles = Candle.hourly
    assert_equal 1, hourly_candles.count
    assert_equal "1h", hourly_candles.first.timeframe
  end

  def test_fifteen_minute_scope
    @valid_candle.save!

    # Create a 15m candle
    candle_15m = Candle.create!(
      symbol: "BTC-USD",
      timeframe: "15m",
      timestamp: Time.now.utc,
      open: 50000.0,
      high: 51000.0,
      low: 49000.0,
      close: 50500.0,
      volume: 100.5
    )

    fifteen_min_candles = Candle.fifteen_minute
    assert_equal 1, fifteen_min_candles.count
    assert_equal "15m", fifteen_min_candles.first.timeframe
  end

  def test_decimal_precision
    @valid_candle.open = 123456.7890123456
    @valid_candle.high = 123456.7890123456
    @valid_candle.low = 123456.7890123456
    @valid_candle.close = 123456.7890123456
    @valid_candle.volume = 123456789.123456789

    assert @valid_candle.valid?
    @valid_candle.save!

    # Reload and check precision is maintained (within database precision limits)
    reloaded = Candle.find(@valid_candle.id)
    assert_in_delta 123456.7890123456, reloaded.open.to_f, 0.0001
    assert_in_delta 123456.7890123456, reloaded.high.to_f, 0.0001
    assert_in_delta 123456.7890123456, reloaded.low.to_f, 0.0001
    assert_in_delta 123456.7890123456, reloaded.close.to_f, 0.0001
    assert_in_delta 123456789.123456789, reloaded.volume.to_f, 0.0001
  end
end
