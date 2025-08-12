# frozen_string_literal: true

require "faraday"
require "json"
require "openssl"
require "base64"
require "securerandom"

module Trading
  class CoinbasePositions
    DEFAULT_BASE = "https://api.coinbase.com"

    def initialize(base_url: ENV.fetch("COINBASE_AT_REST_URL", DEFAULT_BASE), logger: Rails.logger)
      @logger = logger
      @conn = Faraday.new(base_url) do |f|
        f.request :url_encoded
        f.response :raise_error
        f.adapter Faraday.default_adapter
      end

      if ENV["COINBASE_API_KEY"] && ENV["COINBASE_API_SECRET"]
        @api_key = ENV["COINBASE_API_KEY"]
        @api_secret = ENV["COINBASE_API_SECRET"]
        @authenticated = true
      else
        @authenticated = false
        @logger.warn("Coinbase API credentials not fully configured. Positions API requires authentication.")
      end
    end

    # List open positions. Optionally filter by product_id (e.g., "BTC-USD-PERP").
    # Returns array of positions.
    def list_open_positions(product_id: nil)
      raise "Authentication required" unless @authenticated

      path = "/api/v3/brokerage/positions"
      params = {}
      params[:product_ids] = product_id if product_id

      resp = authenticated_get(path, params)
      data = JSON.parse(resp.body)

      positions = if data.is_a?(Hash) && data["positions"]
        data["positions"]
      else
        data
      end

      positions = [ positions ] unless positions.is_a?(Array)
      positions
    end

    # Open a position by placing an order. By default uses market order.
    # side: :buy or :sell
    # size: String or Numeric quantity in base units
    # price: required for limit orders
    # type: :market or :limit
    # Returns order result hash
    def open_position(product_id:, side:, size:, type: :market, price: nil)
      raise "Authentication required" unless @authenticated

      order_body = build_order_body(product_id: product_id, side: side, size: size, type: type, price: price)
      resp = authenticated_post("/api/v3/brokerage/orders", order_body)
      JSON.parse(resp.body)
    end

    # Close a position by submitting an opposite-side market order for the specified size.
    # If size is nil, attempts to infer the open size from list_open_positions for the product.
    # Returns order result hash
    def close_position(product_id:, size: nil)
      raise "Authentication required" unless @authenticated

      pos_size, pos_side = infer_position(product_id: product_id, explicit_size: size)
      return { "success" => true, "message" => "No open position to close" } if pos_size.to_f <= 0.0

      close_side = pos_side == :buy ? :sell : :buy
      order_body = build_order_body(product_id: product_id, side: close_side, size: pos_size, type: :market)
      resp = authenticated_post("/api/v3/brokerage/orders", order_body)
      JSON.parse(resp.body)
    end

    private

    def build_order_body(product_id:, side:, size:, type:, price: nil)
      side_str = side.to_s.downcase
      raise ArgumentError, "side must be :buy or :sell" unless %w[buy sell].include?(side_str)

      order_config = case type.to_sym
      when :market
        {
          "market_market_ioc" => {
            "base_size" => size.to_s
          }
        }
      when :limit
        raise ArgumentError, "price is required for limit orders" unless price
        {
          "limit_limit_gtc" => {
            "base_size" => size.to_s,
            "limit_price" => price.to_s,
            "post_only" => false
          }
        }
      else
        raise ArgumentError, "unsupported order type: #{type}"
      end

      {
        "client_order_id" => "cli-#{SecureRandom.uuid}",
        "product_id" => product_id,
        "side" => side_str,
        "order_configuration" => order_config
      }
    end

    def infer_position(product_id:, explicit_size: nil)
      return [ explicit_size.to_s, :buy ] if explicit_size # side will be flipped by caller

      positions = list_open_positions(product_id: product_id)
      return [ "0", :buy ] if positions.empty?

      pos = positions.find { |p| p["product_id"] == product_id } || positions.first

      # Try multiple field names to extract size and side
      size = pos["size"] || pos["base_size"] || pos["quantity"] || pos.dig("position", "size") || "0"
      side = pos["side"] || pos["position_side"] || pos.dig("position", "side")

      normalized_side = case side.to_s.downcase
      when "long", "buy" then :buy
      when "short", "sell" then :sell
      else :buy
      end

      [ size.to_s, normalized_side ]
    end

    # --- Auth helpers (Advanced Trade style signing) ---

    def authenticated_get(path, params = {})
      timestamp = Time.now.to_i.to_s
      method = "GET"

      # Build the exact request path string used for signing, including query if present
      query = params.any? ? "?" + params.map { |k, v| "#{k}=#{v}" }.join("&") : ""
      prehash = timestamp + method + path + query

      signature = hmac_sha256(prehash)

      set_auth_headers(timestamp, signature)
      @conn.headers["Accept"] = "application/json"
      @conn.get(path, params)
    end

    def authenticated_post(path, body_hash = {})
      timestamp = Time.now.to_i.to_s
      method = "POST"

      body_json = JSON.dump(body_hash)
      prehash = timestamp + method + path + body_json

      signature = hmac_sha256(prehash)

      set_auth_headers(timestamp, signature)
      @conn.headers["Content-Type"] = "application/json"
      @conn.headers["Accept"] = "application/json"
      @conn.post(path, body_json)
    end

    def set_auth_headers(timestamp, signature)
      @conn.headers["CB-ACCESS-KEY"] = @api_key
      @conn.headers["CB-ACCESS-SIGN"] = signature
      @conn.headers["CB-ACCESS-TIMESTAMP"] = timestamp
    end

    def hmac_sha256(data)
      # Advanced Trade: secret is base64; signature must be base64(HMAC_SHA256(decode64(secret), prehash))
      decoded_secret = Base64.decode64(@api_secret)
      raw_hmac = OpenSSL::HMAC.digest("sha256", decoded_secret, data)
      Base64.strict_encode64(raw_hmac)
    end
  end
end
