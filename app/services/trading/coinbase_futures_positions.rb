# frozen_string_literal: true

require "faraday"
require "json"
require "openssl"

module Trading
  class CoinbaseFuturesPositions
    DEFAULT_BASE = "https://api.coinbase.com"

    def initialize(base_url: ENV.fetch("COINBASE_AT_REST_URL", DEFAULT_BASE), logger: Rails.logger)
      @logger = logger
      @conn = Faraday.new(base_url) do |f|
        f.request :url_encoded
        f.response :raise_error
        f.adapter Faraday.default_adapter
      end

      # Use Advanced Trade API credentials (JWT)
      if ENV["COINBASE_API_KEY"] && ENV["COINBASE_API_SECRET"]
        @api_key = ENV["COINBASE_API_KEY"]
        @api_secret = ENV["COINBASE_API_SECRET"]
        @authenticated = true
        @logger.info("Using Advanced Trade API credentials for futures positions")
      else
        @authenticated = false
        @logger.warn("Coinbase Advanced Trade API credentials not configured. Using public API only.")
      end
    end

    # Test authentication with a simple endpoint
    def test_auth
      raise "Authentication required" unless @authenticated

      path = "/api/v3/brokerage/accounts"
      begin
        resp = authenticated_get(path)
        data = JSON.parse(resp.body)
        { ok: true, count: data.is_a?(Array) ? data.size : 1, data: data }
      rescue Faraday::ClientError => e
        body = (e.response && e.response[:body]).to_s
        { ok: false, error: e.class.to_s, message: e.message, body: body }
      end
    end

    # List open positions for futures products
    def list_open_positions(product_id: nil)
      raise "Authentication required" unless @authenticated

      path = "/api/v3/brokerage/cfm/positions"
      params = {}
      params[:product_id] = product_id if product_id

      begin
        resp = authenticated_get(path, params)
        data = JSON.parse(resp.body)

        # Handle different response formats
        positions = if data.is_a?(Array)
          data
        elsif data.is_a?(Hash) && data["positions"]
          data["positions"]
        else
          data
        end

        positions = [ positions ] unless positions.is_a?(Array)

        # Filter for futures products if not already filtered
        if product_id.nil?
          positions = positions.select { |p| p["product_id"]&.end_with?("-PERP") || p["product_id"] == "BTC-USD" || p["product_id"] == "ETH-USD" }
        end

        positions
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
    end

    # Get account balances
    def get_accounts
      raise "Authentication required" unless @authenticated

      path = "/api/v3/brokerage/accounts"
      resp = authenticated_get(path)
      JSON.parse(resp.body)
    end

    # Get specific account details
    def get_account(account_id)
      raise "Authentication required" unless @authenticated

      path = "/api/v3/brokerage/accounts/#{account_id}"
      resp = authenticated_get(path)
      JSON.parse(resp.body)
    end

    private

    # Authenticated GET request with Advanced Trade API JWT signing
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
        aud: "retail_rest_api",
        uri: uri
      }

      private_key = begin
        # Ruby/OpenSSL can read both PKCS#1/8 via OpenSSL::PKey.read
        OpenSSL::PKey.read(@api_secret)
      rescue OpenSSL::PKey::PKeyError
        OpenSSL::PKey::EC.new(@api_secret)
      end

      jwt = JWT.encode(payload, private_key, "ES256")
      @logger.debug("Generated JWT for #{http_method} #{request_path}: #{jwt[0..50]}...")
      jwt
    end

    # Match Coinbase Python SDK jwt_generator.format_jwt_uri() behavior
    # See: https://docs.cdp.coinbase.com/coinbase-app/authentication-authorization/api-key-authentication
    def format_jwt_uri(http_method, request_path, params, body)
      # Coinbase expects: "METHOD /path" format for the uri claim
      method = http_method.to_s.upcase
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

      "#{method} #{path_with_query}"
    end

    def normalize_pem_secret(secret)
      pem = secret.to_s
      # Support .env with escaped newlines
      pem = pem.gsub("\\n", "\n")
      pem.strip
    end
  end
end
