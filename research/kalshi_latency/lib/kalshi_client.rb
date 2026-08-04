require "net/http"
require "json"
require "uri"

require_relative "watchlist"
require_relative "order_book"
require_relative "kalshi_signer"

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

  # Credentials are OPTIONAL and read-only. With them the full orderbook is
  # available instead of top-of-book alone, which is what turns a guess about
  # capacity into a measurement. This client issues GETs only -- there is no
  # order path here, so a leaked or misused key cannot place a trade through it.
  def initialize(base: BASE, logger: nil, key_id: nil, private_key_pem: nil)
    @base = base
    @logger = logger
    @signer = if key_id.to_s.strip.empty? || private_key_pem.to_s.strip.empty?
      nil
    else
      KalshiSigner.new(key_id: key_id, private_key_pem: private_key_pem)
    end
  end

  def self.from_env(logger: nil)
    new(logger: logger, key_id: ENV["KALSHI_KEY_ID"], private_key_pem: ENV["KALSHI_KEY"])
  end

  def authenticated?
    !@signer.nil?
  end

  # Full book for one market. Requires credentials; without them Kalshi returns
  # only the touch, and reporting that as depth would understate capacity by an
  # order of magnitude.
  def order_book(ticker, depth: 10)
    return nil unless authenticated?

    OrderBook.parse(get("/markets/#{ticker}/orderbook", depth: depth))
  rescue RequestFailed => e
    log("orderbook #{ticker} failed: #{e.message}")
    nil
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

  # Every open market in a daily-high series for one local date. The date is
  # encoded in the ticker as e.g. 26AUG04, so filtering on it keeps tomorrow's
  # contracts out of today's comparison.
  def temp_markets(series_ticker, local_date)
    body = get("/markets", series_ticker: series_ticker, status: "open", limit: 200)
    stamp = local_date.strftime("%y%b%d").upcase

    (body["markets"] || []).select { |m| m["ticker"].to_s.include?("-#{stamp}-") }
  end

  # Every open market in a series. Unlike temp_markets this does not filter by
  # date: one-touch windows span weeks and the whole series is in play.
  def series_markets(series_ticker, limit: 100)
    body = get("/markets", series_ticker: series_ticker, status: "open", limit: limit)
    (body["markets"] || []).select { |m| m["yes_ask_dollars"].to_f > 0 }
  rescue RequestFailed => e
    log("series_markets #{series_ticker} failed: #{e.message}")
    []
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

    response = with_retries { fetch(uri, path) }
    raise RequestFailed, "GET #{path} -> HTTP #{response.code}" unless response.code == "200"

    JSON.parse(response.body)
  end

  # Signed only when credentials were supplied; the public endpoints stay public.
  def fetch(uri, path)
    return Net::HTTP.get_response(uri) unless @signer

    http = Net::HTTP.new(uri.host, 443)
    http.use_ssl = true
    http.open_timeout = 10
    http.read_timeout = 15
    http.get(uri.request_uri, @signer.headers_for(method: "GET", path: "/trade-api/v2#{path}"))
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
