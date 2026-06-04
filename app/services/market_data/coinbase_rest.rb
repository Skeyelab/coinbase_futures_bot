# frozen_string_literal: true

require "faraday"
require "json"
require "openssl"
require "jwt"

module MarketData
  class CoinbaseRest
    DEFAULT_BASE = "https://api.coinbase.com"

    # Granularity strings for Advanced Trade API
    GRANULARITY = {
      60 => "ONE_MINUTE",
      300 => "FIVE_MINUTE",
      900 => "FIFTEEN_MINUTE",
      3600 => "ONE_HOUR"
    }.freeze

    def initialize(base_url: ENV.fetch("COINBASE_REST_URL", DEFAULT_BASE))
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
        Rails.logger.warn("Coinbase API credentials not fully configured. Using public API only.")
      end
    end

    def list_products
      resp = authenticated_get("/api/v3/brokerage/products", {product_type: "FUTURE"})
      data = JSON.parse(resp.body)
      products = data["products"] || []
      Rails.logger.info("Fetched #{products.count} products from Advanced Trade API")
      products
    end

    def upsert_products
      products = list_products
      futures_products = products.select { |p| p["product_id"] =~ /^(BIT|ET|NOL)-/ && !p["trading_disabled"] }

      futures_products.each do |p|
        contract_info = TradingPair.parse_contract_info(p["product_id"])
        next unless contract_info

        TradingPair.upsert({
          product_id: p["product_id"],
          base_currency: contract_info[:base_currency],
          quote_currency: contract_info[:quote_currency],
          expiration_date: contract_info[:expiration_date],
          contract_type: contract_info[:contract_type],
          status: "active",
          min_size: p["base_min_size"],
          price_increment: p["quote_increment"],
          size_increment: p["base_increment"],
          enabled: true,
          created_at: Time.now.utc,
          updated_at: Time.now.utc
        }, unique_by: :index_trading_pairs_on_product_id)
      end

      Rails.logger.info("Upserted #{futures_products.count} futures products")
    end

    # Returns array of arrays: [ time, low, high, open, close, volume ]
    # granularity in seconds: 60, 300, 900, 3600
    def fetch_candles(product_id:, start_iso8601: nil, end_iso8601: nil, granularity: 3600)
      gran_str = GRANULARITY.fetch(granularity, "ONE_HOUR")
      params = {granularity: gran_str}
      params[:start] = Time.parse(start_iso8601).to_i.to_s if start_iso8601
      params[:end] = Time.parse(end_iso8601).to_i.to_s if end_iso8601

      resp = authenticated_get("/api/v3/brokerage/products/#{product_id}/candles", params)
      data = JSON.parse(resp.body)

      if data["candles"]
        data["candles"].map do |c|
          [c["start"].to_i, c["low"], c["high"], c["open"], c["close"], c["volume"]]
        end
      elsif data["error"]
        Rails.logger.error("Candles API error: #{data["error"]}")
        raise "API Error: #{data["error"]}"
      else
        Rails.logger.warn("Unknown candles format: #{data.keys}")
        []
      end
    end

    # Fetch candles in chunks to avoid API limits
    def fetch_candles_in_chunks(product_id:, start_time:, end_time: Time.now.utc, chunk_days: 30)
      all_data = []
      current_start = start_time

      while current_start < end_time
        current_end = [current_start + chunk_days.days, end_time].min
        begin
          chunk_data = fetch_candles(
            product_id: product_id,
            start_iso8601: current_start.iso8601,
            end_iso8601: current_end.iso8601,
            granularity: 3600
          )
          all_data.concat(chunk_data)
          current_start = current_end
          # Small delay to avoid rate limiting
          sleep(0.1) if chunk_data.any?
        rescue => e
          Rails.logger.error("Failed to fetch candles chunk for #{product_id} from #{current_start} to #{current_end}: #{e.message}")
          current_start = current_end
        end
      end

      all_data
    end

    # Upsert candles into DB as `Candle` records (1h)
    def upsert_1h_candles(product_id:, start_time:, end_time: Time.now.utc)
      # For larger date ranges, use chunked fetching to avoid API limits
      if (end_time - start_time) > 3.days
        upsert_1h_candles_chunked(product_id: product_id, start_time: start_time, end_time: end_time)
        return
      end

      data = fetch_candles(product_id: product_id, start_iso8601: start_time.iso8601, end_iso8601: end_time.iso8601, granularity: 3600)

      # Debug logging
      Rails.logger.info("Processing #{data.class} data with #{data.count} items for 1h candles")

      # Ensure data is an array
      unless data.is_a?(Array)
        Rails.logger.error("Expected array data, got #{data.class}: #{data.inspect[0..200]}")
        return
      end

      # API returns most recent first; normalize oldest→newest
      data.sort_by { |arr| arr[0].to_i }.each do |arr|
        next unless arr.is_a?(Array) && arr.length >= 6

        ts = Time.at(arr[0]).utc
        low, high, open, close, volume = arr[1..5]

        # Use create_or_find_by instead of upsert for debugging
        Candle.create_or_find_by(
          symbol: product_id,
          timeframe: "1h",
          timestamp: ts
        ) do |candle|
          candle.open = open
          candle.high = high
          candle.low = low
          candle.close = close
          candle.volume = volume
        end
      end

      Rails.logger.info("Completed upserting 1h candles for #{product_id}")
    end

    # Upsert 15-minute candles
    def upsert_15m_candles(product_id:, start_time:, end_time: Time.now.utc)
      # For larger date ranges, use chunked fetching to avoid API limits
      if (end_time - start_time) > 3.days
        upsert_15m_candles_chunked(product_id: product_id, start_time: start_time, end_time: end_time)
        return
      end

      # Use 15m granularity (900 seconds)
      data = fetch_candles(product_id: product_id, start_iso8601: start_time.iso8601, end_iso8601: end_time.iso8601, granularity: 900)

      # Debug logging
      Rails.logger.info("Processing #{data.class} data with #{data.count} items for 15m candles")

      # Ensure data is an array
      unless data.is_a?(Array)
        Rails.logger.error("Expected array data, got #{data.class}: #{data.inspect[0..200]}")
        return
      end

      # API returns most recent first; normalize oldest→newest
      data.sort_by { |arr| arr[0].to_i }.each do |arr|
        next unless arr.is_a?(Array) && arr.length >= 6

        ts = Time.at(arr[0]).utc
        low, high, open, close, volume = arr[1..5]

        # Use create_or_find_by instead of upsert for debugging
        Candle.create_or_find_by(
          symbol: product_id,
          timeframe: "15m",
          timestamp: ts
        ) do |candle|
          candle.open = open
          candle.high = high
          candle.low = low
          candle.close = close
          candle.volume = volume
        end
      end

      Rails.logger.info("Completed upserting 15m candles for #{product_id}")
    end

    # Upsert 15-minute candles using chunked fetching for large date ranges
    def upsert_15m_candles_chunked(product_id:, start_time:, end_time: Time.now.utc, chunk_days: 3)
      all_data = []
      current_start = start_time

      while current_start < end_time
        current_end = [current_start + chunk_days.days, end_time].min
        begin
          chunk_data = fetch_candles(
            product_id: product_id,
            start_iso8601: current_start.iso8601,
            end_iso8601: current_end.iso8601,
            granularity: 900
          )
          all_data.concat(chunk_data)
          current_start = current_end
          # Small delay to avoid rate limiting
          sleep(0.1) if chunk_data.any?
        rescue => e
          Rails.logger.error("Failed to fetch 15m candles chunk for #{product_id} from #{current_start} to #{current_end}: #{e.message}")
          current_start = current_end
        end
      end

      # Process all the collected data
      Rails.logger.info("Processing #{all_data.count} total 15m candles in chunks")

      all_data.sort_by { |arr| arr[0].to_i }.each do |arr|
        next unless arr.is_a?(Array) && arr.length >= 6

        ts = Time.at(arr[0]).utc
        low, high, open, close, volume = arr[1..5]

        Candle.create_or_find_by(
          symbol: product_id,
          timeframe: "15m",
          timestamp: ts
        ) do |candle|
          candle.open = open
          candle.high = high
          candle.low = low
          candle.close = close
          candle.volume = volume
        end
      end

      Rails.logger.info("Completed upserting #{all_data.count} 15m candles in chunks for #{product_id}")
    end

    # Upsert 5-minute candles
    def upsert_5m_candles(product_id:, start_time:, end_time: Time.now.utc)
      # For larger date ranges, use chunked fetching to avoid API limits
      if (end_time - start_time) > 2.days
        upsert_5m_candles_chunked(product_id: product_id, start_time: start_time, end_time: end_time)
        return
      end

      # Use 5m granularity (300 seconds)
      data = fetch_candles(product_id: product_id, start_iso8601: start_time.iso8601, end_iso8601: end_time.iso8601, granularity: 300)

      # Debug logging
      Rails.logger.info("Processing #{data.class} data with #{data.count} items for 5m candles")

      # Ensure data is an array
      unless data.is_a?(Array)
        Rails.logger.error("Expected array data, got #{data.class}: #{data.inspect[0..200]}")
        return
      end

      # API returns most recent first; normalize oldest→newest
      data.sort_by { |arr| arr[0].to_i }.each do |arr|
        next unless arr.is_a?(Array) && arr.length >= 6

        ts = Time.at(arr[0]).utc
        low, high, open, close, volume = arr[1..5]

        # Use create_or_find_by instead of upsert for debugging
        Candle.create_or_find_by(
          symbol: product_id,
          timeframe: "5m",
          timestamp: ts
        ) do |candle|
          candle.open = open
          candle.high = high
          candle.low = low
          candle.close = close
          candle.volume = volume
        end
      end

      Rails.logger.info("Completed upserting 5m candles for #{product_id}")
    end

    # Upsert 5-minute candles using chunked fetching for large date ranges
    def upsert_5m_candles_chunked(product_id:, start_time:, end_time: Time.now.utc, chunk_days: 2)
      all_data = []
      current_start = start_time

      while current_start < end_time
        current_end = [current_start + chunk_days.days, end_time].min
        begin
          chunk_data = fetch_candles(
            product_id: product_id,
            start_iso8601: current_start.iso8601,
            end_iso8601: current_end.iso8601,
            granularity: 300
          )
          all_data.concat(chunk_data)
          current_start = current_end
          # Small delay to avoid rate limiting
          sleep(0.1) if chunk_data.any?
        rescue => e
          Rails.logger.error("Failed to fetch 5m candles chunk for #{product_id} from #{current_start} to #{current_end}: #{e.message}")
          current_start = current_end
        end
      end

      # Process all the collected data
      Rails.logger.info("Processing #{all_data.count} total 5m candles in chunks")

      all_data.sort_by { |arr| arr[0].to_i }.each do |arr|
        next unless arr.is_a?(Array) && arr.length >= 6

        ts = Time.at(arr[0]).utc
        low, high, open, close, volume = arr[1..5]

        Candle.create_or_find_by(
          symbol: product_id,
          timeframe: "5m",
          timestamp: ts
        ) do |candle|
          candle.open = open
          candle.high = high
          candle.low = low
          candle.close = close
          candle.volume = volume
        end
      end

      Rails.logger.info("Completed upserting #{all_data.count} 5m candles in chunks for #{product_id}")
    end

    # Upsert 1-minute candles
    def upsert_1m_candles(product_id:, start_time:, end_time: Time.now.utc)
      # For larger date ranges, use chunked fetching to avoid API limits
      if (end_time - start_time) > 1.day
        upsert_1m_candles_chunked(product_id: product_id, start_time: start_time, end_time: end_time)
        return
      end

      # Use 1m granularity (60 seconds)
      data = fetch_candles(product_id: product_id, start_iso8601: start_time.iso8601, end_iso8601: end_time.iso8601, granularity: 60)

      # Debug logging
      Rails.logger.info("Processing #{data.class} data with #{data.count} items for 1m candles")

      # Ensure data is an array
      unless data.is_a?(Array)
        Rails.logger.error("Expected array data, got #{data.class}: #{data.inspect[0..200]}")
        return
      end

      # API returns most recent first; normalize oldest→newest
      data.sort_by { |arr| arr[0].to_i }.each do |arr|
        next unless arr.is_a?(Array) && arr.length >= 6

        ts = Time.at(arr[0]).utc
        low, high, open, close, volume = arr[1..5]

        # Use create_or_find_by instead of upsert for debugging
        Candle.create_or_find_by(
          symbol: product_id,
          timeframe: "1m",
          timestamp: ts
        ) do |candle|
          candle.open = open
          candle.high = high
          candle.low = low
          candle.close = close
          candle.volume = volume
        end
      end

      Rails.logger.info("Completed upserting 1m candles for #{product_id}")
    end

    # Upsert 1-minute candles using chunked fetching for large date ranges
    def upsert_1m_candles_chunked(product_id:, start_time:, end_time: Time.now.utc, chunk_days: 1)
      all_data = []
      current_start = start_time

      while current_start < end_time
        current_end = [current_start + chunk_days.days, end_time].min
        begin
          chunk_data = fetch_candles(
            product_id: product_id,
            start_iso8601: current_start.iso8601,
            end_iso8601: current_end.iso8601,
            granularity: 60
          )
          all_data.concat(chunk_data)
          current_start = current_end
          # Small delay to avoid rate limiting
          sleep(0.1) if chunk_data.any?
        rescue => e
          Rails.logger.error("Failed to fetch 1m candles chunk for #{product_id} from #{current_start} to #{current_end}: #{e.message}")
          current_start = current_end
        end
      end

      # Process all the collected data
      Rails.logger.info("Processing #{all_data.count} total 1m candles in chunks")

      all_data.sort_by { |arr| arr[0].to_i }.each do |arr|
        next unless arr.is_a?(Array) && arr.length >= 6

        ts = Time.at(arr[0]).utc
        low, high, open, close, volume = arr[1..5]

        Candle.create_or_find_by(
          symbol: product_id,
          timeframe: "1m",
          timestamp: ts
        ) do |candle|
          candle.open = open
          candle.high = high
          candle.low = low
          candle.close = close
          candle.volume = volume
        end
      end

      Rails.logger.info("Completed upserting #{all_data.count} 1m candles in chunks for #{product_id}")
    end

    # Upsert candles using chunked fetching for large date ranges
    def upsert_1h_candles_chunked(product_id:, start_time:, end_time: Time.now.utc, chunk_days: 30)
      data = fetch_candles_in_chunks(product_id: product_id, start_time: start_time, end_time: end_time, chunk_days: chunk_days)
      # API returns most recent first; normalize oldest→newest
      data.sort_by { |arr| arr[0].to_i }.each do |arr|
        ts = Time.at(arr[0]).utc
        low, high, open, close, volume = arr[1..5]
        Candle.upsert({
          symbol: product_id,
          timeframe: "1h",
          timestamp: ts,
          open: open,
          high: high,
          low: low,
          close: close,
          volume: volume,
          created_at: Time.now.utc,
          updated_at: Time.now.utc
        }, unique_by: :index_candles_on_symbol_and_timeframe_and_timestamp)
      end
    end

    private

    def authenticated_get(path, params = {})
      now = Time.now.to_i
      payload = {
        sub: @api_key,
        iss: "cdp",
        nbf: now,
        exp: now + 120,
        uri: "GET api.coinbase.com#{path}"
      }
      pkey = OpenSSL::PKey.read(@api_secret)
      token = JWT.encode(payload, pkey, "ES256", {kid: @api_key, nonce: SecureRandom.hex(16)})

      @conn.headers["Authorization"] = "Bearer #{token}"
      @conn.headers["Content-Type"] = "application/json"
      @conn.get(path, params)
    end

    # Update current month contracts using the FuturesContractManager
    def update_current_month_contracts
      manager = FuturesContractManager.new
      manager.update_current_month_contracts
    end

    # Update all contracts (current and upcoming month) using the FuturesContractManager
    def update_all_contracts
      manager = FuturesContractManager.new
      manager.update_all_contracts
    end
  end
end
