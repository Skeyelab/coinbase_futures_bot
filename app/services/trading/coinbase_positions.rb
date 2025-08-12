# frozen_string_literal: true

require "faraday"
require "json"
require "openssl"
require "base64"
require "jwt"
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

      if ENV["COINBASE_API_KEY"] && (ENV["COINBASE_API_SECRET"] || ENV["COINBASE_API_SECRET_FILE"]) 
        @api_key = ENV["COINBASE_API_KEY"] # e.g., organizations/{org_id}/apiKeys/{key_id}
        secret_source = if ENV["COINBASE_API_SECRET_FILE"].present?
          File.read(ENV["COINBASE_API_SECRET_FILE"]).to_s
        else
          ENV["COINBASE_API_SECRET"].to_s
        end
        @api_secret = normalize_pem_secret(secret_source) # PEM ECDSA private key for ES256
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

      begin
      resp = authenticated_get(path, params)
        data = JSON.parse(resp.body)
      rescue Faraday::ClientError => e
        body = (e.response && e.response[:body]).to_s
        message = begin
          parsed = JSON.parse(body)
          parsed["message"] || parsed["error"] || body
        rescue
          body.presence || e.message
        end
        raise Faraday::ClientError.new("#{e.message}#{": #{message}" if message}", response: e.response)
      end

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
      @conn.headers["Accept"] = "application/json"
      @conn.headers["Authorization"] = "Bearer #{build_jwt_token("GET", path, params: params)}"
      @conn.get(path, params)
    end

    def authenticated_post(path, body_hash = {})
      body_json = JSON.dump(body_hash)
      @conn.headers["Content-Type"] = "application/json"
      @conn.headers["Accept"] = "application/json"
      @conn.headers["Authorization"] = "Bearer #{build_jwt_token("POST", path, body: body_json)}"
      @conn.post(path, body_json)
    end

    # Build ES256 JWT per Coinbase App API requirements (Authorization: Bearer <JWT>)
    # See: https://docs.cdp.coinbase.com/coinbase-app/authentication-authorization/api-key-authentication
    def build_jwt_token(http_method, request_path, params: nil, body: nil)
      now = Time.now.to_i
      exp = now + 120 # expires in 2 minutes
      uri = format_jwt_uri(http_method, request_path, params, body)

      payload = {
        iss: @api_key,
        nbf: now,
        exp: exp,
        sub: @api_key,
        uri: uri
      }

      private_key = begin
        # Ruby/OpenSSL can read both PKCS#1/8 via OpenSSL::PKey.read
        OpenSSL::PKey.read(@api_secret)
      rescue OpenSSL::PKey::PKeyError
        OpenSSL::PKey::EC.new(@api_secret)
      end
      JWT.encode(payload, private_key, "ES256")
    end

    # Match SDK formatting for JWT uri claim
    def format_jwt_uri(http_method, request_path, params, body)
      method = http_method.to_s.upcase
      case method
      when "GET", "DELETE"
        if params&.any?
          query = params.map { |k, v| "#{k}=#{v}" }.join("&")
          "#{request_path}?#{query}"
        else
          request_path
        end
      when "POST", "PUT"
        request_path
      else
        request_path
      end
    end

    def normalize_pem_secret(secret)
      pem = secret.to_s
      # Support .env with escaped newlines
      pem = pem.gsub("\\n", "\n")
      pem.strip
    end
  end
end
