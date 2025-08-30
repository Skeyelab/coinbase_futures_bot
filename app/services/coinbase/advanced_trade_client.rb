# frozen_string_literal: true

require "faraday"
require "json"
require "openssl"
require "jwt"
require "cgi"

module Coinbase
  class AdvancedTradeClient
    include SentryServiceTracking

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

      track_api_call(path, "test_auth") do
        resp = authenticated_get(path)
        data = JSON.parse(resp.body)
        {ok: true, count: data.is_a?(Array) ? data.size : 1, data: data}
      end
    rescue Faraday::ClientError => e
      body = (e.response && e.response[:body]).to_s
      {ok: false, error: e.class.to_s, message: e.message, body: body}
    end

    # Get account balances
    def get_accounts
      raise "Authentication required" unless @authenticated

      path = "/api/v3/brokerage/accounts"
      track_api_call(path, "get_accounts") do
        resp = authenticated_get(path)
        JSON.parse(resp.body)
      end
    end

    # Get specific account details
    def get_account(account_id)
      raise "Authentication required" unless @authenticated

      path = "/api/v3/brokerage/accounts/#{account_id}"
      track_api_call(path, "get_account") do
        resp = authenticated_get(path)
        JSON.parse(resp.body)
      end
    end

    # List futures positions
    def list_futures_positions(product_id: nil)
      raise "Authentication required" unless @authenticated

      path = "/api/v3/brokerage/cfm/positions"
      params = {}
      params[:product_id] = product_id if product_id

      track_api_call(path, "list_futures_positions") do
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

        # Add breadcrumb for successful position retrieval
        SentryHelper.add_breadcrumb(
          message: "Retrieved futures positions",
          category: "trading",
          level: "info",
          data: {
            product_id: product_id,
            position_count: positions.size
          }
        )

        positions
      end
    end

    # Alias for backward compatibility with tests
    alias_method :list_positions, :list_futures_positions

    # Place an order (placeholder for integration tests)
    def place_order(order_data)
      raise "Authentication required" unless @authenticated

      path = "/api/v3/brokerage/orders"
      begin
        resp = authenticated_post(path, order_data)
        JSON.parse(resp.body)
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

    # Get product ticker (for price data)
    def get_product_ticker(product_id)
      raise "Authentication required" unless @authenticated

      path = "/api/v3/brokerage/market/products/#{product_id}/ticker"
      resp = authenticated_get(path)
      JSON.parse(resp.body)
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

    # Authenticated POST request
    def authenticated_post(path, body_hash = {})
      # Clear any existing Authorization header to ensure fresh JWT
      @conn.headers.delete("Authorization")

      body_json = JSON.dump(body_hash)

      # Set required headers that Coinbase API expects
      @conn.headers["Content-Type"] = "application/json"
      @conn.headers["Accept"] = "application/json"

      # Generate completely new JWT for this specific request
      jwt = build_jwt_token("POST", path, body: body_json)
      @conn.headers["Authorization"] = "Bearer #{jwt}"

      @logger.debug("POST #{path} with fresh JWT and required headers")

      begin
        resp = @conn.post(path, body_json)
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

    # Helper method to track API calls and errors in Sentry
    def track_api_call(endpoint, operation, &block)
      SentryHelper.add_breadcrumb(
        message: "Coinbase Advanced Trade API call",
        category: "api",
        level: "info",
        data: {
          service: "advanced_trade",
          endpoint: endpoint,
          operation: operation
        }
      )

      start_time = Time.current
      result = yield
      duration = (Time.current - start_time) * 1000 # Convert to milliseconds

      # Track successful API calls for performance monitoring
      SentryHelper.add_breadcrumb(
        message: "API call completed successfully",
        category: "api",
        level: "info",
        data: {
          service: "advanced_trade",
          endpoint: endpoint,
          operation: operation,
          duration_ms: duration.round(2)
        }
      )

      result
    rescue Faraday::ClientError => e
      duration = (Time.current - start_time) * 1000

      # Enhanced error tracking for API failures
      Sentry.with_scope do |scope|
        scope.set_tag("service", "coinbase_advanced_trade")
        scope.set_tag("endpoint", endpoint)
        scope.set_tag("operation", operation)
        scope.set_tag("error_type", "api_client_error")

        scope.set_context("api_call", {
          endpoint: endpoint,
          operation: operation,
          duration_ms: duration.round(2),
          response_status: e.response&.dig(:status),
          response_body: e.response&.dig(:body),
          authenticated: @authenticated
        })

        Sentry.capture_exception(e)
      end

      raise
    rescue => e
      duration = (Time.current - start_time) * 1000

      # Track unexpected errors
      Sentry.with_scope do |scope|
        scope.set_tag("service", "coinbase_advanced_trade")
        scope.set_tag("endpoint", endpoint)
        scope.set_tag("operation", operation)
        scope.set_tag("error_type", "unexpected_error")

        scope.set_context("api_call", {
          endpoint: endpoint,
          operation: operation,
          duration_ms: duration.round(2),
          authenticated: @authenticated
        })

        Sentry.capture_exception(e)
      end

      raise
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
      pem = pem.gsub('\\n', "\n")
      pem.strip
    end
  end
end
