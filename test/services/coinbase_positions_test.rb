# frozen_string_literal: true

require "test_helper"

class CoinbasePositionsTest < ActiveSupport::TestCase
  def setup
    @orig_key = ENV["COINBASE_API_KEY"]
    @orig_secret = ENV["COINBASE_API_SECRET"]
    ENV["COINBASE_API_KEY"] = "k"
    ENV["COINBASE_API_SECRET"] = "s"

    @service = Trading::CoinbasePositions.new(base_url: "https://example.com")
  end

  def teardown
    ENV["COINBASE_API_KEY"] = @orig_key
    ENV["COINBASE_API_SECRET"] = @orig_secret
  end

  def test_list_open_positions_basic
    mock_response = Minitest::Mock.new
    body = {
      "positions" => [
        { "product_id" => "BTC-USD-PERP", "size" => "0.01", "side" => "long" }
      ]
    }.to_json
    mock_response.expect :body, body

    conn = @service.instance_variable_get(:@conn)
    conn.stub :get, mock_response do
      positions = @service.list_open_positions
      assert_equal 1, positions.size
      assert_equal "BTC-USD-PERP", positions.first["product_id"]
    end
  end

  def test_open_position_market
    mock_response = Minitest::Mock.new
    mock_response.expect :body, { "success" => true, "order_id" => "abc" }.to_json

    conn = @service.instance_variable_get(:@conn)
    conn.stub :post, mock_response do
      res = @service.open_position(product_id: "BTC-USD-PERP", side: :buy, size: "0.01")
      assert res["success"]
    end
  end

  def test_open_position_limit_requires_price
    assert_raises(ArgumentError) do
      @service.open_position(product_id: "BTC-USD-PERP", side: :buy, size: "0.01", type: :limit)
    end
  end

  def test_close_position_uses_inferred_size
    # Stub list_open_positions to return an existing position
    @service.stub :list_open_positions, [ { "product_id" => "BTC-USD-PERP", "size" => "0.02", "side" => "long" } ] do
      mock_response = Minitest::Mock.new
      mock_response.expect :body, { "success" => true, "order_id" => "def" }.to_json

      conn = @service.instance_variable_get(:@conn)
      conn.stub :post, mock_response do
        res = @service.close_position(product_id: "BTC-USD-PERP")
        assert res["success"]
      end
    end
  end

  def test_close_position_when_no_open_size
    @service.stub :list_open_positions, [] do
      res = @service.close_position(product_id: "BTC-USD-PERP")
      assert_equal true, res["success"]
      assert_match /No open position/, res["message"]
    end
  end
end