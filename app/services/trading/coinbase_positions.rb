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

      # Try to load credentials from cdp_api_key.json file (same as AdvancedTradeClient)
      credentials = load_credentials_from_file

      if credentials
        @api_key = credentials[:api_key]
        @api_secret = credentials[:private_key]
        @authenticated = true
        @logger.info("CoinbasePositions service initialized with credentials from cdp_api_key.json")
      else
        @authenticated = false
        @logger.warn("CoinbasePositions service credentials not found in cdp_api_key.json")
      end
    end

    # Test method to validate auth with simpler endpoint first
    def test_auth_with_accounts
      raise "Authentication required" unless @authenticated

      path = "/api/v3/brokerage/accounts"
      begin
        resp = authenticated_get(path, {})
        data = JSON.parse(resp.body)
        { ok: true, count: data.is_a?(Array) ? data.size : 1, data: data }
      rescue Faraday::ClientError => e
        body = (e.response && e.response[:body]).to_s
        { ok: false, error: e.class.to_s, message: e.message, body: body }
      end
    end

    # List open positions. Optionally filter by product_id (e.g., "BTC-USD-PERP").
    # Returns array of positions.
    def list_open_positions(product_id: nil)
      raise "Authentication required" unless @authenticated

      # Use the correct futures positions endpoint
      # Note: Coinbase API doesn't support filtering by product_id, so we fetch all and filter in Ruby
      path = "/api/v3/brokerage/cfm/positions"
      params = {}  # Don't pass product_id to API

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

      # Filter by product_id in Ruby if specified
      if product_id
        positions = positions.select { |p| p["product_id"] == product_id }
      end

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

      # For futures, flip LONG to SHORT and vice versa
      close_side = case pos_side
      when :long then :short
      when :short then :long
      when :buy then :sell
      when :sell then :buy
      else :short  # Default fallback
      end

      order_body = build_order_body(product_id: product_id, side: close_side, size: pos_size, type: :market)

      @logger.info("Closing position: product_id=#{product_id}, size=#{pos_size}, side=#{pos_side} -> #{close_side}")
      @logger.info("Order body: #{order_body.inspect}")

      resp = authenticated_post("/api/v3/brokerage/orders", order_body)
      JSON.parse(resp.body)
    end

    private

    def build_order_body(product_id:, side:, size:, type:, price: nil)
      # For futures orders, use LONG/SHORT instead of buy/sell
      side_str = case side.to_s.downcase
      when "long" then "LONG"
      when "short" then "SHORT"
      when "buy" then "BUY"
      when "sell" then "SELL"
      else
        raise ArgumentError, "side must be :long, :short, :buy, or :sell, got: #{side}"
      end

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

      # For futures positions, use number_of_contracts as the primary size field
      size = pos["number_of_contracts"] || pos["size"] || pos["base_size"] || pos["quantity"] || pos.dig("position", "size") || "0"
      side = pos["side"] || pos["position_side"] || pos.dig("position", "side")

      # For futures orders, use LONG/SHORT instead of buy/sell
      normalized_side = case side.to_s.upcase
      when "LONG" then :long
      when "SHORT" then :short
      when "BUY" then :buy
      when "SELL" then :sell
      else :long  # Default to long
      end

      [ size.to_s, normalized_side ]
    end

    # --- Auth helpers (Advanced Trade style signing) ---

    def authenticated_get(path, params = {})
      @conn.headers["Accept"] = "application/json"
      jwt = build_jwt_token("GET", path, params: params)
      @conn.headers["Authorization"] = "Bearer #{jwt}"

      @logger.debug("GET #{path} with JWT payload: #{jwt[0..100]}...")
      @logger.debug("Headers: #{@conn.headers.slice('Accept', 'Authorization').inspect}")

      begin
        resp = @conn.get(path, params)
        resp
      rescue Faraday::ClientError => e
        @logger.error("Request failed: #{e.class} - #{e.message}")
        if e.response
          @logger.error("Response status: #{e.response[:status]}")
          @logger.error("Response headers: #{e.response[:headers]}")
          @logger.error("Response body: #{e.response[:body]}")
        end
        raise
      end
    end

    def authenticated_post(path, body_hash = {})
      body_json = JSON.dump(body_hash)
      @conn.headers["Content-Type"] = "application/json"
      @conn.headers["Accept"] = "application/json"
      @conn.headers["Authorization"] = "Bearer #{build_jwt_token("POST", path, body: body_json)}"

      @logger.debug("POST #{path} with body: #{body_json}")
      @logger.debug("Headers: #{@conn.headers.slice('Content-Type', 'Accept', 'Authorization').inspect}")

      begin
        resp = @conn.post(path, body_json)
        resp
      rescue Faraday::ClientError => e
        @logger.error("Request failed: #{e.class} - #{e.message}")
        if e.response
          @logger.error("Response status: #{e.response[:status]}")
          @logger.error("Response headers: #{e.response[:headers]}")
          @logger.error("Response body: #{e.response[:body]}")
        end
        raise
      end
    end

    # Build ES256 JWT per Coinbase App API requirements (Authorization: Bearer <JWT>)
    # See: https://docs.cdp.coinbase.com/coinbase-app/authentication-authorization/api-key-authentication
    def build_jwt_token(http_method, request_path, params: nil, body: nil)
      now = Time.now.to_i
      exp = now + 120 # expires in 2 minutes
      uri = format_jwt_uri(http_method, request_path, params, body)

      payload = {
        sub: @api_key,
        iss: "cdp",
        nbf: now,
        exp: exp,
        uri: uri
      }

      private_key = begin
        # Ruby/OpenSSL can read both PKCS#1/8 via OpenSSL::PKey.read
        OpenSSL::PKey.read(@api_secret)
      rescue OpenSSL::PKey::PKeyError
        OpenSSL::PKey::EC.new(@api_secret)
      end

      # Include kid header for clarity; some infrastructures rely on it
      # Use the full API key path like the Python implementation
      jwt = JWT.encode(payload, private_key, "ES256", { kid: @api_key })
      @logger.debug("Generated JWT for #{http_method} #{request_path}: #{jwt[0..50]}...")
      jwt
    end

    # Match Coinbase Python SDK jwt_generator.format_jwt_uri() behavior
    # See: https://docs.cdp.coinbase.com/coinbase-app/authentication-authorization/api-key-authentication
    def format_jwt_uri(http_method, request_path, params, body)
      # Coinbase expects: "METHOD api.coinbase.com/path" format for the uri claim
      method = http_method.to_s.upcase
      host = "api.coinbase.com"

      path_with_query = case method
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

      "#{method} #{host}#{path_with_query}"
    end

    def load_credentials_from_file
      file_path = Rails.root.join("cdp_api_key.json")

      if File.exist?(file_path)
        begin
          data = JSON.parse(File.read(file_path))

          # Use the full organization path as the API key
          # This is what Coinbase expects for JWT authentication
          api_key = data["name"]
          private_key = data["privateKey"]

          @logger.info("Using API key: #{api_key}")
          @logger.info("Private key length: #{private_key.length}")

          {
            api_key: api_key,
            private_key: private_key
          }
        rescue JSON::ParserError => e
          @logger.error("Failed to parse cdp_api_key.json: #{e.message}")
          nil
        rescue => e
          @logger.error("Failed to load credentials from cdp_api_key.json: #{e.message}")
          nil
        end
      else
        @logger.warn("cdp_api_key.json file not found at #{file_path}")
        nil
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
