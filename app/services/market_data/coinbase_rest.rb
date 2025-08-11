# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module MarketData
  class CoinbaseRest
    DEFAULT_BASE = "https://api.exchange.coinbase.com"

    def initialize(base_url: ENV.fetch("COINBASE_REST_URL", DEFAULT_BASE))
      @base_uri = URI(base_url)
    end

    def list_products
      get_json("/products")
    end

    def upsert_products
      products = list_products
      products.each do |p|
        next unless p["status"] == "online" && p["quote_currency"] == "USD"
        TradingPair.upsert({
          product_id: p["id"],
          base_currency: p["base_currency"],
          quote_currency: p["quote_currency"],
          status: p["status"],
          min_size: p.dig("base_increment"),
          price_increment: p.dig("quote_increment"),
          size_increment: p.dig("base_increment"),
          enabled: true,
          created_at: Time.now.utc,
          updated_at: Time.now.utc
        }, unique_by: :index_trading_pairs_on_product_id)
      end
    end

    def fetch_candles(product_id:, start_iso8601: nil, end_iso8601: nil, granularity: 3600)
      params = { granularity: granularity }
      params[:start] = start_iso8601 if start_iso8601
      params[:end] = end_iso8601 if end_iso8601
      get_json("/products/#{product_id}/candles", params)
    end

    def upsert_1h_candles(product_id:, start_time:, end_time: Time.now.utc)
      data = fetch_candles(product_id: product_id, start_iso8601: start_time.iso8601, end_iso8601: end_time.iso8601, granularity: 3600)
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

    private

    def get_json(path, params = nil)
      uri = @base_uri.dup
      uri.path = File.join(uri.path, path)
      uri.query = URI.encode_www_form(params) if params && !params.empty?
      req = Net::HTTP::Get.new(uri)
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
        res = http.request(req)
        raise "HTTP #{res.code}: #{res.body}" unless res.is_a?(Net::HTTPSuccess)
        JSON.parse(res.body)
      end
    end
  end
end