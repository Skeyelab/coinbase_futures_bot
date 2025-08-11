# frozen_string_literal: true

require "faraday"
require "json"

module MarketData
  class CoinbaseRest
    DEFAULT_BASE = "https://api.exchange.coinbase.com"

    def initialize(base_url: ENV.fetch("COINBASE_REST_URL", DEFAULT_BASE))
      @conn = Faraday.new(base_url) do |f|
        f.request :url_encoded
        f.response :raise_error
        f.adapter Faraday.default_adapter
      end
    end

    # Returns array of arrays: [ time, low, high, open, close, volume ] per Coinbase public API
    # granularity in seconds: 3600 for 1h
    def fetch_candles(product_id:, start_iso8601: nil, end_iso8601: nil, granularity: 3600)
      params = { granularity: granularity }
      params[:start] = start_iso8601 if start_iso8601
      params[:end] = end_iso8601 if end_iso8601
      resp = @conn.get("/products/#{product_id}/candles", params)
      JSON.parse(resp.body)
    end

    # Upsert candles into DB as `Candle` records (1h)
    def upsert_1h_candles(product_id:, start_time:, end_time: Time.now.utc)
      data = fetch_candles(product_id: product_id, start_iso8601: start_time.iso8601, end_iso8601: end_time.iso8601, granularity: 3600)
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
        }, unique_by: :index_candles_on_symbol_timeframe_timestamp)
      end
    end
  end
end