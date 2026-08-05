require "net/http"
require "json"
require "uri"
require "time"

# Running minimum and maximum of a price over a window.
#
# One-touch markets resolve on whether price EVER reached a level, so the
# extremes must come from candle HIGHS and LOWS. A wick that touched $59,900
# and closed back at $61,000 still settles the market -- reading closes would
# miss every touch that did not persist, which is most of them.
#
# BASIS RISK, unresolved: Kalshi's rules say "the price of BTC" without naming
# an index. This reads Coinbase spot. If Kalshi settles against something else,
# every verdict built on this is wrong in the same way METAR-versus-CLI is
# wrong on the weather side. Do not trade a one-touch on this until the index
# is confirmed.
module PriceExtremes
  BASE = "https://api.coinbase.com/api/v3/brokerage/market/products"
  MAX_CANDLES = 300

  def self.from_candles(candles)
    lows = []
    highs = []

    Array(candles).each do |c|
      low = c["low"].to_f
      high = c["high"].to_f
      next if low <= 0 || high <= 0

      lows << low
      highs << high
    end

    {min: lows.min, max: highs.max, bars: lows.size}
  end

  # Coinbase caps a request at ~350 candles, so a month of hourly data needs
  # several. Granularity is chosen to cover the window rather than fixed:
  # asking for ONE_HOUR over 30 days would silently truncate to the most
  # recent 300 hours and report a minimum that never happened.
  def self.for_window(product_id, from:, to:, granularity: nil)
    granularity ||= coarse_enough(from, to)
    seconds = GRANULARITY_SECONDS.fetch(granularity)
    candles = []
    cursor = from.to_i

    while cursor < to.to_i
      chunk_end = [cursor + (MAX_CANDLES * seconds), to.to_i].min
      candles.concat(fetch(product_id, cursor, chunk_end, granularity))
      cursor = chunk_end
    end

    from_candles(candles).merge(granularity: granularity)
  end

  GRANULARITY_SECONDS = {
    "ONE_MINUTE" => 60, "FIVE_MINUTE" => 300, "FIFTEEN_MINUTE" => 900,
    "ONE_HOUR" => 3600, "SIX_HOUR" => 21_600, "ONE_DAY" => 86_400
  }.freeze

  # The finest granularity whose full window fits inside the request cap.
  # Finer is better -- a one-touch can happen inside a single bar, and a daily
  # candle's low is the whole day's low, so coarse data OVERSTATES how deep the
  # touch went only if you read closes, and understates nothing if you read
  # wicks. Wicks are what we read, so coarse is safe but imprecise on timing.
  def self.coarse_enough(from, to)
    span = to.to_i - from.to_i
    GRANULARITY_SECONDS.find { |_, secs| span / secs <= MAX_CANDLES * 12 }&.first || "ONE_DAY"
  end

  def self.fetch(product_id, start_ts, end_ts, granularity)
    uri = URI("#{BASE}/#{product_id}/candles")
    uri.query = URI.encode_www_form(start: start_ts, end: end_ts, granularity: granularity)
    response = Net::HTTP.get_response(uri)
    return [] unless response.code == "200"

    JSON.parse(response.body)["candles"] || []
  rescue
    []
  end
end
