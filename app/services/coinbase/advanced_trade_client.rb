# frozen_string_literal: true

require "faraday"
require "json"
require "openssl"
require "jwt"
require "cgi"

module Coinbase
  class AdvancedTradeClient
    DEFAULT_BASE = "https://api.coinbase.com"

    def initialize(base_url: ENV.fetch("COINBASE_AT_REST_URL", DEFAULT_BASE), logger: Rails.logger)
      @logger = logger
      @conn = Faraday.new(base_url) do |f|
        f.request :url_encoded
        f.response :raise_error
        f.adapter Faraday.default_adapter
      end

      # Try to load credentials from cdp_api_key.json file
      credentials = load_credentials_from_file

      if credentials
        @api_key = credentials[:api_key]
        @api_secret = normalize_pem_secret(credentials[:private_key])
        @authenticated = true
        @logger.info("Advanced Trade API client initialized with credentials from cdp_api_key.json")
      else
        @authenticated = false
        @logger.warn("Advanced Trade API credentials not found in cdp_api_key.json")
      end
    end

    # Test authentication with accounts endpoint
    def test_auth
      raise "Authentication required" unless @authenticated

      path = "/api/v3/brokerage/accounts"
      begin
        resp = authenticated_get(path)
        data = JSON.parse(resp.body)
        {ok: true, count: data.is_a?(Array) ? data.size : 1, data: data}
      rescue Faraday::ClientError => e
        body = (e.response && e.response[:body]).to_s
        {ok: false, error: e.class.to_s, message: e.message, body: body}
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

    # List futures positions
    def list_futures_positions(product_id: nil)
      raise "Authentication required" unless @authenticated

      path = "/api/v3/brokerage/cfm/positions"
      params = {}
      params[:product_id] = product_id if product_id

      begin
        resp = authenticated_get(path, params)
        data = JSON.parse(resp.body)

        positions = if data.is_a?(Array)
          data
        elsif data.is_a?(Hash) && data["positions"]
          data["positions"]
        else
          data
        end

        positions = [positions] unless positions.is_a?(Array)
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

    # Get futures balance summary
    def get_futures_balance_summary
      raise "Authentication required" unless @authenticated
      path = "/api/v3/brokerage/cfm/balance_summary"
      resp = authenticated_get(path)
      JSON.parse(resp.body)
    end

    # Get current margin window
    # Docs: GET /cfm/intraday/current_margin_window
    # https://docs.cdp.coinbase.com/coinbase-app/advanced-trade-apis/rest-api
    def get_current_margin_window
      raise "Authentication required" unless @authenticated
      path = "/api/v3/brokerage/cfm/intraday/current_margin_window"
      resp = authenticated_get(path)
      JSON.parse(resp.body)
    end

    # Get API key permissions (this will tell us what our key can do)
    def get_api_key_permissions
      raise "Authentication required" unless @authenticated
      path = "/api/v3/brokerage/key_permissions"
      resp = authenticated_get(path)
      JSON.parse(resp.body)
    end

    # List all available products (including futures contracts)
    def list_products
      raise "Authentication required" unless @authenticated
      path = "/api/v3/brokerage/market/products"
      resp = authenticated_get(path)
      data = JSON.parse(resp.body)

      # The response should contain a 'products' array
      products = (data.is_a?(Hash) && data["products"]) ? data["products"] : data
      products = [products] unless products.is_a?(Array)
      products
    end

    # Get specific product details
    def get_product(product_id)
      raise "Authentication required" unless @authenticated
      path = "/api/v3/brokerage/market/products/#{product_id}"
      resp = authenticated_get(path)
      JSON.parse(resp.body)
    end

    private

    # Load credentials from cdp_api_key.json file
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

    # Generate a fresh JWT token for each request
    def authenticated_get(path, params = {})
      # Clear any existing Authorization header to ensure fresh JWT
      @conn.headers.delete("Authorization")

      # Set required headers that Coinbase API expects
      @conn.headers["Accept"] = "application/json"
      @conn.headers["Content-Type"] = "application/json"

      # Generate completely new JWT for this specific request
      jwt = build_jwt_token("GET", path, params: params)
      @conn.headers["Authorization"] = "Bearer #{jwt}"

      @logger.debug("GET #{path} with fresh JWT and required headers")

      begin
        resp = @conn.get(path, params)
        # Clear the Authorization header after the request to ensure no reuse
        @conn.headers.delete("Authorization")
        resp
      rescue Faraday::ClientError => e
        # Clear the Authorization header even on error
        @conn.headers.delete("Authorization")
        @logger.error("Request failed: #{e.class} - #{e.message}")
        if e.response
          @logger.error("Response status: #{e.response[:status]}")
          @logger.error("Response body: #{e.response[:body]}")
        end
        raise
      end
    end

    # Build ES256 JWT per Coinbase App API requirements
    # Each request gets a unique JWT with fresh timestamp
    def build_jwt_token(http_method, request_path, params: nil, body: nil)
      # JWT validity window
      now = Time.now.to_i
      exp = now + 120 # expires in 120 seconds (matching Python)
      uri = format_jwt_uri(http_method, request_path, params, body)

      payload = {
        sub: @api_key,
        iss: "cdp",
        nbf: now,
        exp: exp,
        uri: uri
      }

      @logger.debug("JWT URI for signing: #{uri}")
      @logger.debug("JWT time window: nbf=#{now}, exp=#{exp}")

      private_key = begin
        OpenSSL::PKey.read(@api_secret)
      rescue OpenSSL::PKey::PKeyError
        OpenSSL::PKey::EC.new(@api_secret)
      end

      # Include kid header for clarity; some infrastructures rely on it
      # Use the full API key path like the Python implementation
      JWT.encode(payload, private_key, "ES256", {kid: @api_key})
    end

    # Format URI for JWT claim per Coinbase requirements
    # Follow Python SDK behavior: include host in URI
    # https://docs.cdp.coinbase.com/coinbase-app/authentication-authorization/api-key-authentication
    def format_jwt_uri(http_method, request_path, params, _body)
      method = http_method.to_s.upcase
      host = "api.coinbase.com"

      path_with_query = case method
      when "GET", "DELETE"
        if params && !params.empty?
          query = params.map { |k, v| "#{k}=#{v}" }.join("&")
          "#{request_path}?#{query}"
        else
          request_path
        end
      else
        request_path
      end

      "#{method} #{host}#{path_with_query}"
    end

    # Minimal RFC3986 percent-encoding (space as %20, leave ~ unescaped)
    def rfc3986_encode(str)
      encoded = CGI.escape(str)
      encoded.gsub("+", "%20").gsub("%7E", "~")
    end

    def normalize_pem_secret(secret)
      pem = secret.to_s
      pem = pem.gsub("\\n", "\n")
      pem.strip
    end
  end
end
