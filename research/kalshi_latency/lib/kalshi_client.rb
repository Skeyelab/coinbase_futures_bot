require "net/http"
require "json"
require "uri"

require_relative "watchlist"

# Read-only Kalshi market data. No credentials, no orders, no gems.
#
# Two things the API makes non-obvious and that cost an afternoon to find:
#
#   1. GET /markets is useless for discovery. It returns tens of thousands of
#      auto-generated combination markets before any real one, so paging it
#      finds nothing tradeable. Real markets come from
#      GET /events?with_nested_markets=true.
#   2. Every numeric field arrives as a *string*, and prices are in dollars
#      ("0.4200"), not cents. Watchlist.normalize does the conversion.
class KalshiClient
  BASE = "https://api.elections.kalshi.com/trade-api/v2".freeze
  MAX_TICKERS_PER_REQUEST = 100

  class RequestFailed < StandardError; end

  def initialize(base: BASE, logger: nil)
    @base = base
    @logger = logger
  end

  # Walks the event listing and returns the markets worth sampling.
  def discover(min_volume_24h:, limit:, max_pages: 30)
    markets = []
    cursor = nil
    pages = 0

    while pages < max_pages
      params = {limit: 200, status: "open", with_nested_markets: true}
      params[:cursor] = cursor if cursor

      body = get("/events", params)
      (body["events"] || []).each { |event| markets.concat(event["markets"] || []) }

      cursor = body["cursor"]
      pages += 1
      break if cursor.nil? || cursor.empty?
    end

    log("discovered #{markets.size} raw markets over #{pages} pages")
    Watchlist.select_from(markets, min_volume_24h: min_volume_24h, limit: limit)
  end

  # Current top-of-book for many tickers. Batched to stay inside rate limits.
  def quotes(tickers)
    tickers.each_slice(MAX_TICKERS_PER_REQUEST).flat_map do |batch|
      body = get("/markets", tickers: batch.join(","))
      (body["markets"] || []).map { |m| Watchlist.normalize(m) }
    end
  end

  private

  def get(path, params = {})
    uri = URI("#{@base}#{path}")
    uri.query = URI.encode_www_form(params) unless params.empty?

    response = with_retries { Net::HTTP.get_response(uri) }
    raise RequestFailed, "GET #{path} -> HTTP #{response.code}" unless response.code == "200"

    JSON.parse(response.body)
  end

  # The collector is meant to run unattended for weeks. A blip must not end it.
  def with_retries(attempts: 4)
    delay = 1
    last_error = nil

    attempts.times do |i|
      begin
        response = yield
        return response if response.code == "200"
        last_error = "HTTP #{response.code}"
      rescue => e
        last_error = "#{e.class}: #{e.message}"
      end

      break if i == attempts - 1
      sleep(delay)
      delay *= 2
    end

    raise RequestFailed, "gave up after #{attempts} attempts (#{last_error})"
  end

  def log(message)
    @logger&.call("[kalshi] #{message}")
  end
end
