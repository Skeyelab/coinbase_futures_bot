# frozen_string_literal: true

require "faraday"
require "json"
require "openssl"

module Coinbase
  class ExchangeClient
    DEFAULT_BASE = "https://api.exchange.coinbase.com"

    def initialize(base_url: ENV.fetch("COINBASE_REST_URL", DEFAULT_BASE), logger: Rails.logger)
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
        @api_secret = credentials[:private_key]
        @authenticated = true
        @logger.info("Exchange API client initialized with credentials from cdp_api_key.json")
      else
        @authenticated = false
        @logger.warn("Exchange API credentials not found in cdp_api_key.json - using public endpoints only")
      end
    end

    # Test authentication with accounts endpoint
    def test_auth
      raise "Authentication required" unless @authenticated

      path = "/accounts"
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
      path = "/accounts"
      resp = authenticated_get(path)
      JSON.parse(resp.body)
    end

    # Get specific account details
    def get_account(account_id)
      raise "Authentication required" unless @authenticated
      path = "/accounts/#{account_id}"
      resp = authenticated_get(path)
      JSON.parse(resp.body)
    end

    # List products (public endpoint)
    def list_products
      resp = @conn.get("/products")
      data = JSON.parse(resp.body)

      products = if data.is_a?(Array)
        data
      elsif data.is_a?(Hash) && data["products"]
        data["products"]
      else
        data
      end

      products = [products] unless products.is_a?(Array)
      products
    end

    # Get product details
    def get_product(product_id)
      resp = @conn.get("/products/#{product_id}")
      JSON.parse(resp.body)
    end

    # Get product candles
    def get_candles(product_id, start_time: nil, end_time: nil, granularity: 3600)
      params = {granularity: granularity}
      params[:start] = start_time.iso8601 if start_time
      params[:end] = end_time.iso8601 if end_time

      resp = @conn.get("/products/#{product_id}/candles", params)
      JSON.parse(resp.body)
    end

    # Get product ticker
    def get_ticker(product_id)
      resp = @conn.get("/products/#{product_id}/ticker")
      JSON.parse(resp.body)
    end

    # Get product stats
    def get_stats(product_id)
      resp = @conn.get("/products/#{product_id}/stats")
      JSON.parse(resp.body)
    end

    # Get server time
    def get_time
      resp = @conn.get("/time")
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

    # Authenticated GET request with Exchange API HMAC-SHA256 signing
    def authenticated_get(path, params = {})
      timestamp = Time.now.to_i.to_s
      method = "GET"

      # Build the prehash string
      prehash_string = timestamp + method + path
      if params.any?
        query_string = params.map { |k, v| "#{k}=#{v}" }.join("&")
        prehash_string += "?" + query_string
      end

      # Create the signature
      signature = OpenSSL::HMAC.hexdigest(
        OpenSSL::Digest.new("sha256"),
        @api_secret,
        prehash_string
      )

      # Set headers
      @conn.headers["CB-ACCESS-KEY"] = @api_key
      @conn.headers["CB-ACCESS-SIGN"] = signature
      @conn.headers["CB-ACCESS-TIMESTAMP"] = timestamp

      @logger.debug("GET #{path} with HMAC signature")

      # Make the request
      @conn.get(path, params)
    end
  end
end
