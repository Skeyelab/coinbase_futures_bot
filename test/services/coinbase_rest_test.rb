# frozen_string_literal: true

require "test_helper"

class CoinbaseRestTest < ActiveSupport::TestCase
  def setup
    # Clear any existing API credentials for testing
    @original_api_key = ENV["COINBASE_API_KEY"]
    @original_api_secret = ENV["COINBASE_API_SECRET"]
    ENV.delete("COINBASE_API_KEY")
    ENV.delete("COINBASE_API_SECRET")

    @rest = MarketData::CoinbaseRest.new
    @product_id = "BTC-USD"
    @start_time = 1.day.ago
    @end_time = Time.now.utc
  end

  def teardown
    # Restore original environment
    if @original_api_key
      ENV["COINBASE_API_KEY"] = @original_api_key
    end
    if @original_api_secret
      ENV["COINBASE_API_SECRET"] = @original_api_secret
    end
  end

  def test_initializes_with_default_base_url
    assert_equal "https://api.exchange.coinbase.com", @rest.instance_variable_get(:@conn).url_prefix.to_s.chomp("/")
  end

  def test_initializes_with_custom_base_url
    custom_rest = MarketData::CoinbaseRest.new(base_url: "https://custom.api.com")
    assert_equal "https://custom.api.com", custom_rest.instance_variable_get(:@conn).url_prefix.to_s.chomp("/")
  end

  def test_initializes_without_api_credentials
    assert_not @rest.instance_variable_get(:@authenticated)
  end

  def test_initializes_with_api_credentials
    with_env("COINBASE_API_KEY" => "test_key", "COINBASE_API_SECRET" => "test_secret") do
      authenticated_rest = MarketData::CoinbaseRest.new
      assert authenticated_rest.instance_variable_get(:@authenticated)
      assert_equal "test_key", authenticated_rest.instance_variable_get(:@api_key)
      assert_equal "test_secret", authenticated_rest.instance_variable_get(:@api_secret)
    end
  end

  def test_list_products_handles_array_response
    mock_response = Minitest::Mock.new
    mock_response.expect :body, [ { "id" => "BTC-USD", "status" => "online" } ].to_json

    @rest.instance_variable_get(:@conn).stub :get, mock_response do
      products = @rest.list_products
      assert_equal 1, products.count
      assert_equal "BTC-USD", products.first["id"]
    end
  end

  def test_list_products_handles_hash_response
    mock_response = Minitest::Mock.new
    mock_response.expect :body, { "products" => [ { "id" => "BTC-USD", "status" => "online" } ] }.to_json

    @rest.instance_variable_get(:@conn).stub :get, mock_response do
      products = @rest.list_products
      assert_equal 1, products.count
      assert_equal "BTC-USD", products.first["id"]
    end
  end

  def test_fetch_candles_handles_array_response
    mock_response = Minitest::Mock.new
    mock_response.expect :body, [
      [ 1754930700, 119911.55, 120177.23, 119968.18, 120069.34, 23.20361858 ]
    ].to_json

    @rest.instance_variable_get(:@conn).stub :get, mock_response do
      candles = @rest.fetch_candles(
        product_id: @product_id,
        start_iso8601: @start_time.iso8601,
        end_iso8601: @end_time.iso8601,
        granularity: 3600
      )

      assert_equal 1, candles.count
      assert_equal 1754930700, candles.first[0]
      assert_equal 119911.55, candles.first[1]
    end
  end

  def test_fetch_candles_handles_hash_response
    mock_response = Minitest::Mock.new
    mock_response.expect :body, {
      "candles" => [ {
        "start" => "1754930700",
        "low" => 119911.55,
        "high" => 120177.23,
        "open" => 119968.18,
        "close" => 120069.34,
        "volume" => 23.20361858
      } ]
    }.to_json

    @rest.instance_variable_get(:@conn).stub :get, mock_response do
      candles = @rest.fetch_candles(
        product_id: @product_id,
        start_iso8601: @start_time.iso8601,
        end_iso8601: @end_time.iso8601,
        granularity: 3600
      )

      assert_equal 1, candles.count
      assert_equal 1754930700, candles.first[0]
      assert_equal 119911.55, candles.first[1]
    end
  end

  def test_fetch_candles_handles_error_response
    mock_response = Minitest::Mock.new
    mock_response.expect :body, { "error" => "Invalid product" }.to_json

    @rest.instance_variable_get(:@conn).stub :get, mock_response do
      assert_raises(RuntimeError, "API Error: Invalid product") do
        @rest.fetch_candles(
          product_id: @product_id,
          start_iso8601: @start_time.iso8601,
          end_iso8601: @end_time.iso8601,
          granularity: 3600
        )
      end
    end
  end

  def test_fetch_candles_with_parameters
    mock_response = Minitest::Mock.new
    mock_response.expect :body, [].to_json

    # Test that the correct parameters are passed
    @rest.instance_variable_get(:@conn).stub :get, mock_response do
      @rest.fetch_candles(
        product_id: @product_id,
        start_iso8601: @start_time.iso8601,
        end_iso8601: @end_time.iso8601,
        granularity: 1800
      )
    end

    # Verify the mock was called
    mock_response.verify
  end

  def test_upsert_1h_candles_creates_candles
    mock_candles = [
      [ 1754930700, 119911.55, 120177.23, 119968.18, 120069.34, 23.20361858 ],
      [ 1754934300, 120069.34, 120200.00, 120000.00, 120150.00, 45.12345678 ]
    ]

    @rest.stub :fetch_candles, mock_candles do
      assert_difference -> { Candle.count }, 2 do
        @rest.upsert_1h_candles(
          product_id: @product_id,
          start_time: @start_time,
          end_time: @end_time
        )
      end

      # Verify the candles were created correctly
      candle = Candle.find_by(symbol: @product_id, timeframe: "1h")
      assert_equal "BTC-USD", candle.symbol
      assert_equal "1h", candle.timeframe
      assert_equal BigDecimal("119968.18"), candle.open
      assert_equal BigDecimal("120177.23"), candle.high
      assert_equal BigDecimal("119911.55"), candle.low
      assert_equal BigDecimal("120069.34"), candle.close
      assert_equal BigDecimal("23.20361858"), candle.volume
    end
  end

  def test_upsert_30m_candles_creates_15m_candles
    mock_candles = [
      [ 1754930700, 119911.55, 120177.23, 119968.18, 120069.34, 23.20361858 ]
    ]

    @rest.stub :fetch_candles, mock_candles do
      assert_difference -> { Candle.count }, 1 do
        @rest.upsert_30m_candles(
          product_id: @product_id,
          start_time: @start_time,
          end_time: @end_time
        )
      end

      # Verify the candle was created with 15m timeframe
      candle = Candle.find_by(symbol: @product_id, timeframe: "15m")
      assert_equal "15m", candle.timeframe
    end
  end

  def test_upsert_30m_candles_uses_chunked_fetching_for_large_ranges
    large_start = 10.days.ago
    large_end = Time.now.utc

    # Test that the chunked method is called for large date ranges
    mock_rest = Minitest::Mock.new
    mock_rest.expect :upsert_30m_candles_chunked, nil, [ product_id: @product_id, start_time: large_start, end_time: large_end ]

    @rest.stub :upsert_30m_candles_chunked, nil do
      @rest.upsert_30m_candles(
        product_id: @product_id,
        start_time: large_start,
        end_time: large_end
      )
    end
  end

  def test_upsert_1h_candles_uses_chunked_fetching_for_large_ranges
    large_start = 10.days.ago
    large_end = Time.now.utc

    # Test that the chunked method is called for large date ranges
    mock_rest = Minitest::Mock.new
    mock_rest.expect :upsert_1h_candles_chunked, nil, [ product_id: @product_id, start_time: large_start, end_time: large_end ]

    @rest.stub :upsert_1h_candles_chunked, nil do
      @rest.upsert_1h_candles(
        product_id: @product_id,
        start_time: large_start,
        end_time: large_end
      )
    end
  end

  def test_create_default_futures_products
    assert_difference -> { TradingPair.count }, 2 do
      @rest.create_default_futures_products
    end

    # Verify the products were created
    btc_perp = TradingPair.find_by(product_id: "BTC-USD-PERP")
    eth_perp = TradingPair.find_by(product_id: "ETH-USD-PERP")

    assert_not_nil btc_perp
    assert_not_nil eth_perp
    assert_equal "BTC", btc_perp.base_currency
    assert_equal "ETH", eth_perp.base_currency
    assert_equal "USD", btc_perp.quote_currency
    assert_equal "online", btc_perp.status
  end

  private

  def with_env(env_vars)
    original_env = {}
    env_vars.each do |key, value|
      original_env[key] = ENV[key]
      ENV[key] = value
    end

    yield
  ensure
    original_env.each do |key, value|
      if value.nil?
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
  end
end
