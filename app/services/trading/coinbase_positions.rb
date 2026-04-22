# frozen_string_literal: true

require "faraday"
require "json"
require "openssl"
require "base64"
require "jwt"
require "securerandom"

module Trading
  class CoinbasePositions
    include SentryServiceTracking

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

      # Initialize contract manager for current month contract resolution
      @contract_manager = MarketData::FuturesContractManager.new(logger: logger)
    end

    # Test method to validate auth with simpler endpoint first
    def test_auth_with_accounts
      raise "Authentication required" unless @authenticated

      path = "/api/v3/brokerage/accounts"
      begin
        resp = authenticated_get(path, {})
        data = JSON.parse(resp.body)
        {ok: true, count: data.is_a?(Array) ? data.size : 1, data: data}
      rescue Faraday::ClientError => e
        body = (e.response && e.response[:body]).to_s
        {ok: false, error: e.class.to_s, message: e.message, body: body}
      end
    end

    # List open positions. Optionally filter by product_id (e.g., "BTC-USD").
    # Returns array of positions.
    def list_open_positions(product_id: nil)
      raise "Authentication required" unless @authenticated

      # Use the correct futures positions endpoint
      # Note: Coinbase API doesn't support filtering by product_id, so we fetch all and filter in Ruby
      path = "/api/v3/brokerage/cfm/positions"
      params = {} # Don't pass product_id to API

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

      positions = [positions] unless positions.is_a?(Array)

      # Filter by product_id in Ruby if specified
      positions = positions.select { |p| p["product_id"] == product_id } if product_id

      positions
    end

    # Open a position by placing an order. By default uses market order.
    # side: :buy or :sell
    # size: String or Numeric quantity in base units
    # price: required for limit orders
    # type: :market or :limit
    # Returns order result hash
    def open_position(product_id:, side:, size:, type: :market, price: nil, day_trading: nil, take_profit: nil,
      stop_loss: nil)
      # Use configuration default if not specified
      day_trading = Rails.application.config.default_day_trading if day_trading.nil?
      raise "Authentication required" unless @authenticated

      order_body = build_order_body(product_id: product_id, side: side, size: size, type: type, price: price)
      resp = authenticated_post("/api/v3/brokerage/orders", order_body)
      result = JSON.parse(resp.body)

      # If order was successful, create local Position record
      if result["success"] || result["order_id"]
        create_local_position_record(
          product_id: product_id,
          side: side,
          size: size,
          entry_price: price || get_current_market_price(product_id),
          day_trading: day_trading,
          take_profit: take_profit,
          stop_loss: stop_loss,
          order_result: result
        )
      end

      result
    end

    # Close a position by submitting an opposite-side market order for the specified size.
    # If size is nil, attempts to infer the open size from list_open_positions for the product.
    # Returns order result hash
    def close_position(product_id:, size: nil)
      raise "Authentication required" unless @authenticated

      # If explicit size provided, still infer side from current position when possible,
      # but avoid failing if positions cannot be fetched (e.g., in tests)
      if size
        pos_size = size.to_s
        begin
          _ignored_size, pos_side = infer_position(product_id: product_id, explicit_size: size)
        rescue => e
          @logger.debug("close_position: could not infer position side with explicit size: #{e.class}: #{e.message}")
          pos_side = :buy
        end
      else
        pos_size, pos_side = infer_position(product_id: product_id, explicit_size: size)
        return {"success" => true, "message" => "No open position to close"} if pos_size.to_f <= 0.0
      end

      close_side = case pos_side
      when :long then :sell
      when :short then :buy
      when :buy then :sell
      when :sell then :buy
      else :sell
      end

      @logger.info("Closing position: product_id=#{product_id}, size=#{pos_size}, position_side=#{pos_side}, order_side=#{close_side}")

      order_body = build_order_body(product_id: product_id, side: close_side, size: pos_size, type: :market)

      @logger.info("Order body: #{order_body.inspect}")

      resp = authenticated_post("/api/v3/brokerage/orders", order_body)
      result = JSON.parse(resp.body)

      # If order was successful, update local Position record
      if result["success"] || result["order_id"]
        update_local_position_record(
          product_id: product_id,
          size: pos_size,
          close_price: get_current_market_price(product_id),
          order_result: result
        )
      end

      result
    end

    # Increase an existing position by adding more contracts in the same direction.
    # Returns order result hash
    def increase_position(product_id:, size:)
      raise "Authentication required" unless @authenticated

      # Get the current position to determine the side
      positions = list_open_positions(product_id: product_id)
      return {"success" => false, "message" => "No open position found to increase"} if positions.empty?

      position = positions.find { |p| p["product_id"] == product_id } || positions.first
      current_side = position["side"] || position["position_side"] || position.dig("position", "side")

      @logger.info("Increasing position debug: product_id=#{product_id}, current_side=#{current_side.inspect}, position=#{position.inspect}")

      # Convert position side to order side for increase:
      # LONG position: BUY more contracts to increase
      # SHORT position: SELL more contracts to increase
      increase_side = case current_side.to_s.upcase
      when "LONG" then :buy
      when "SHORT" then :sell
      when "BUY" then :buy
      when "SELL" then :sell
      else
        @logger.error("Cannot determine position side for increase: #{current_side.inspect}")
        raise "Cannot determine position side for increase: #{current_side.inspect}"
      end

      @logger.info("Increasing position: product_id=#{product_id}, size=#{size}, original_side=#{current_side}, order_side=#{increase_side}")

      order_body = build_order_body(product_id: product_id, side: increase_side, size: size, type: :market)

      @logger.info("Order body: #{order_body.inspect}")

      resp = authenticated_post("/api/v3/brokerage/orders", order_body)
      result = JSON.parse(resp.body)

      # If order was successful, update local Position record
      if result["success"] || result["order_id"]
        increase_local_position_record(
          product_id: product_id,
          additional_size: size,
          additional_price: get_current_market_price(product_id),
          order_result: result
        )
      end

      result
    end

    # Get current market price for a product
    def get_current_market_price(product_id)
      # Try to get current price from recent market data
      # This is a simplified approach - in production you might want to use real-time market data

      # Try to get from recent ticks first
      recent_tick = Tick.where(product_id: product_id)
        .order(observed_at: :desc)
        .first

      return recent_tick.price if recent_tick && recent_tick.observed_at > 5.minutes.ago

      # Fall back to most recent 1-minute candle
      recent_candle = Candle.for_symbol(product_id)
        .one_minute
        .order(timestamp: :desc)
        .first

      return recent_candle.close if recent_candle && recent_candle.timestamp > 5.minutes.ago

      # If no recent data, return nil (caller should handle this)
      @logger.warn("No recent price data for #{product_id}")
      nil
    end

    # Update position method for tests
    def update_current_month_position(product_id, new_size, new_price)
      # Find the most recent open position for this product
      position = Position.open.by_product(product_id).order(:entry_time).last
      return unless position

      # Update the position
      position.update!(
        size: new_size,
        entry_price: new_price
      )

      @logger.info("Updated local position record #{position.id}: size=#{new_size}, price=#{new_price}")
    rescue => e
      @logger.error("Failed to update local position record: #{e.message}")
      # Don't fail the main operation if local record update fails
    end

    # Open position on current month contract for an asset (legacy method, kept for compatibility)
    def open_current_month_position(asset_or_product_id, side = nil, size = nil, price = nil, day_trading: true,
      take_profit: nil, stop_loss: nil)
      # Handle both old and new calling signatures
      if side.nil? && size.nil? # New signature with hash
        product_id = asset_or_product_id
        params = side || {}
        side = params[:side]
        size = params[:size]
        price = params[:price]
        day_trading = params.fetch(:day_trading, true)
        take_profit = params[:take_profit]
        stop_loss = params[:stop_loss]
      else # Old signature with positional params
        asset = asset_or_product_id
        current_month_contract = @contract_manager.current_month_contract(asset)
        raise "No current month contract found for #{asset}" unless current_month_contract

        product_id = current_month_contract
      end

      @logger.info("Opening #{side} position of #{size} contracts on current month contract: #{product_id}")
      open_position(
        product_id: product_id,
        side: side,
        size: size,
        type: :market,
        price: price,
        day_trading: day_trading,
        take_profit: take_profit,
        stop_loss: stop_loss
      )
    end

    # Close position on current month contract for an asset (legacy method, kept for compatibility)
    def close_current_month_position(asset_or_product_id, size = nil)
      # Handle both asset lookup and direct product_id usage
      if asset_or_product_id.include?("-") # Looks like a product_id
        product_id = asset_or_product_id
      else # Looks like an asset (BTC, ETH)
        current_month_contract = @contract_manager.current_month_contract(asset_or_product_id)
        raise "No current month contract found for #{asset_or_product_id}" unless current_month_contract

        product_id = current_month_contract
      end

      @logger.info("Closing position on contract: #{product_id}")
      close_position(product_id: product_id, size: size)
    end

    # Open position on best available contract for an asset (current month preferred, upcoming as fallback)
    def open_best_available_position(asset:, side:, size:, type: :market, price: nil, day_trading: true,
      take_profit: nil, stop_loss: nil)
      best_contract = @contract_manager.best_available_contract(asset)
      raise "No suitable contract found for #{asset}" unless best_contract

      # Check if it's current or upcoming month for logging
      contract = TradingPair.find_by(product_id: best_contract)
      contract_type = if contract&.current_month?
        "current month"
      elsif contract&.upcoming_month?
        "upcoming month"
      else
        "available"
      end

      @logger.info("Opening #{side} position of #{size} contracts on #{contract_type} #{asset} contract: #{best_contract}")
      open_position(
        product_id: best_contract,
        side: side,
        size: size,
        type: type,
        price: price,
        day_trading: day_trading,
        take_profit: take_profit,
        stop_loss: stop_loss
      )
    end

    # Close position on best available contract for an asset
    def close_best_available_position(asset:, size: nil)
      best_contract = @contract_manager.best_available_contract(asset)
      raise "No suitable contract found for #{asset}" unless best_contract

      @logger.info("Closing position on #{asset} contract: #{best_contract}")
      close_position(product_id: best_contract, size: size)
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
      positions = list_open_positions(product_id: product_id)
      return ["0", :buy] if positions.empty?

      pos = positions.find { |p| p["product_id"] == product_id } || positions.first

      # For futures positions, use number_of_contracts as the primary size field
      size = explicit_size || pos["number_of_contracts"] || pos["size"] || pos["base_size"] || pos["quantity"] || pos.dig(
        "position", "size"
      ) || "0"
      side = pos["side"] || pos["position_side"] || pos.dig("position", "side")

      # For futures orders, use LONG/SHORT instead of buy/sell
      normalized_side = case side.to_s.upcase
      when "LONG" then :long
      when "SHORT" then :short
      when "BUY" then :buy
      when "SELL" then :sell
      else :long # Default to long
      end

      [size.to_s, normalized_side]
    end

    # --- Local Position Record Management ---

    def create_local_position_record(product_id:, side:, size:, entry_price:, day_trading:, take_profit:, stop_loss:,
      order_result:)
      # Convert side to LONG/SHORT for futures
      position_side = case side.to_s.downcase
      when "long", "buy" then "LONG"
      when "short", "sell" then "SHORT"
      else "LONG"
      end

      # Calculate take profit and stop loss if not provided
      if take_profit.nil? && day_trading
        # Use 40 bps take profit for day trading (from strategy)
        take_profit = if position_side == "LONG"
          entry_price * (1 + 0.004)
        else
          entry_price * (1 - 0.004)
        end
      end

      if stop_loss.nil? && day_trading
        # Use 30 bps stop loss for day trading (from strategy)
        stop_loss = if position_side == "LONG"
          entry_price * (1 - 0.003)
        else
          entry_price * (1 + 0.003)
        end
      end

      Position.create!(
        product_id: product_id,
        side: position_side,
        size: size,
        entry_price: entry_price,
        entry_time: Time.current,
        status: "OPEN",
        day_trading: day_trading,
        take_profit: take_profit,
        stop_loss: stop_loss,
        trailing_stop_enabled: ActiveModel::Type::Boolean.new.cast(ENV.fetch("TRAILING_STOP_ENABLED", "false")),
        trailing_stop_state: {}
      )

      @logger.info("Created local position record for #{product_id}: #{position_side} #{size} at #{entry_price}")
    rescue => e
      @logger.error("Failed to create local position record: #{e.message}")
      # Don't fail the main operation if local record creation fails
    end

    def update_local_position_record(product_id:, size:, close_price:, order_result:)
      # Find the most recent open position for this product
      position = Position.open.by_product(product_id).order(:entry_time).last
      return unless position

      # Close the position
      position.close_position!(close_price)
      @logger.info("Updated local position record #{position.id} as closed with PnL: #{position.pnl}")
    rescue => e
      @logger.error("Failed to update local position record: #{e.message}")
      # Don't fail the main operation if local record update fails
    end

    def increase_local_position_record(product_id:, additional_size:, additional_price:, order_result:)
      # Find the most recent open position for this product
      position = Position.open.by_product(product_id).order(:entry_time).last
      return unless position

      # Calculate new average entry price
      total_size = position.size + additional_size.to_f
      new_entry_price = ((position.size * position.entry_price) + (additional_size.to_f * additional_price)) / total_size

      # Update the position
      position.update!(
        size: total_size,
        entry_price: new_entry_price
      )

      @logger.info("Updated local position record #{position.id}: size increased to #{total_size}, new avg entry: #{new_entry_price}")
    rescue => e
      @logger.error("Failed to update local position record for increase: #{e.message}")
      # Don't fail the main operation if local record update fails
    end

    # --- Auth helpers (Advanced Trade style signing) ---

    def authenticated_get(path, params = {})
      @conn.headers["Accept"] = "application/json"
      jwt = build_jwt_token("GET", path, params: params)
      @conn.headers["Authorization"] = "Bearer #{jwt}"

      @logger.debug("GET #{path} with JWT payload: #{jwt[0..100]}...")
      @logger.debug("Headers: #{@conn.headers.slice("Accept", "Authorization").inspect}")

      begin
        @conn.get(path, params)
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
      @logger.debug("Headers: #{@conn.headers.slice("Content-Type", "Accept", "Authorization").inspect}")

      begin
        @conn.post(path, body_json)
      rescue Faraday::ClientError => e
        @logger.error("Request failed: #{e.class} - #{e.message}")
        if e.response
          @logger.error("Response status: #{e.response[:status]}")
          @logger.error("Response headers: #{e.response[:headers]}")
          @logger.error("Response body: #{e.response[:body]}")
        end

        # Extract error message from response body for consistent error handling
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
      jwt = JWT.encode(payload, private_key, "ES256", {kid: @api_key})
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
      pem = pem.gsub('\\n', "\n")
      pem.strip
    end

    # --- Current Month Contract Helpers ---

    # Get positions for current month contracts of a specific asset (BTC, ETH)
    def list_current_month_positions(asset:)
      current_month_contract = @contract_manager.current_month_contract(asset)
      return [] unless current_month_contract

      list_open_positions(product_id: current_month_contract)
    end

    # Get positions for upcoming month contracts of a specific asset (BTC, ETH)
    def list_upcoming_month_positions(asset:)
      upcoming_month_contract = @contract_manager.upcoming_month_contract(asset)
      return [] unless upcoming_month_contract

      list_open_positions(product_id: upcoming_month_contract)
    end

    # Get positions for the best available contract for an asset
    def list_best_available_positions(asset:)
      best_contract = @contract_manager.best_available_contract(asset)
      return [] unless best_contract

      list_open_positions(product_id: best_contract)
    end

    # Get all positions grouped by underlying asset
    def positions_by_asset
      all_positions = list_open_positions
      positions_by_asset = {}

      all_positions.each do |position|
        product_id = position["product_id"]
        asset = extract_asset_from_product_id(product_id)
        next unless asset

        positions_by_asset[asset] ||= []
        positions_by_asset[asset] << position
      end

      positions_by_asset
    end

    # Extract asset from product ID
    def extract_asset_from_product_id(product_id)
      case product_id
      when /^(BTC|ETH)(-USD)?$/
        ::Regexp.last_match(1)
      when /^(BIT|ET)-\d{2}[A-Z]{3}\d{2}-[A-Z]+$/
        product_id.start_with?("BIT") ? "BTC" : "ETH"
      end
    end

    # Check if any positions need to be rolled over to current month contracts
    def positions_need_rollover?
      expiring_contracts = @contract_manager.expiring_contracts(days_ahead: 3)
      all_positions = list_open_positions

      # Check if we have positions in any expiring contracts
      expiring_product_ids = expiring_contracts.map(&:product_id)
      all_positions.any? { |pos| expiring_product_ids.include?(pos["product_id"]) }
    end

    # Rollover positions from expiring contracts to current month contracts
    def rollover_positions
      return unless positions_need_rollover?

      @logger.info("Starting position rollover process")
      positions_by_asset.each do |asset, positions|
        rollover_asset_positions(asset, positions)
      end
    end

    private

    def rollover_asset_positions(asset, positions)
      current_month_contract = @contract_manager.current_month_contract(asset)
      return unless current_month_contract

      expiring_positions = positions.select do |pos|
        contract = TradingPair.find_by(product_id: pos["product_id"])
        contract&.expiration_date && contract.expiration_date <= Date.current + 3.days
      end

      return if expiring_positions.empty?

      @logger.info("Rolling over #{expiring_positions.size} #{asset} positions to #{current_month_contract}")

      expiring_positions.each do |position|
        rollover_single_position(position, current_month_contract, asset)
      end
    end

    def rollover_single_position(position, target_contract, asset)
      product_id = position["product_id"]
      size = position["number_of_contracts"] || position["size"]
      side = position["side"]

      @logger.info("Rolling over #{asset} position: #{size} contracts from #{product_id} to #{target_contract}")

      begin
        # Close the old position
        close_position(product_id: product_id, size: size)

        # Open new position in current month contract
        # Convert side: if we had a LONG position, we want to open a LONG position
        new_side = case side.to_s.upcase
        when "LONG" then :long
        when "SHORT" then :short
        else :long
        end

        open_position(
          product_id: target_contract,
          side: new_side,
          size: size,
          type: :market
        )

        @logger.info("Successfully rolled over #{asset} position to #{target_contract}")
      rescue => e
        @logger.error("Failed to rollover #{asset} position: #{e.message}")
        raise
      end
    end
  end
end
