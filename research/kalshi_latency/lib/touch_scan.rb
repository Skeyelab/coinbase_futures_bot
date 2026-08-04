require "time"

require_relative "kalshi_client"
require_relative "price_extremes"
require_relative "ratchet_registry"
require_relative "opportunity"

# Scans one-touch price markets for contracts the underlying has already
# settled but the book has not repriced.
#
# The window matters and is NOT the whole of history: KXBTCMINMON asks whether
# price went below the level "after issuance", so extremes are measured from
# open_time, not from whenever we happen to have data. Using a wider window
# would confirm markets on touches that happened before they existed.
class TouchScan
  # DISABLED 2026-08-04.
  #
  # Kalshi settles crypto against CF BENCHMARKS' REAL TIME INDEX, a composite
  # across venues. PriceExtremes reads Coinbase spot. Those differ, and near a
  # strike the difference decides the outcome -- the same class of error as
  # reading METAR when settlement is the NWS climate report.
  #
  # There is a second problem the index fix would not solve. Kalshi's
  # directional crypto markets settle on the AVERAGE OF 60 RTI PRICES in the
  # final minute before expiry, which is not a one-touch at all and cannot be
  # answered by a running extreme. So this family contains at least two
  # settlement models and the scanner modelled neither correctly.
  #
  # Off rather than approximated. It currently reports zero opportunities, so
  # disabling costs nothing today -- but it would confidently report a false
  # one the moment BTC approached $60,000, and a signal nobody can trust does
  # not belong in the same output as one they can.
  #
  # To re-enable: source RTI itself, confirm which series use touch versus
  # final-average settlement, and re-verify against a settled market.
  ENABLED = false
  DISABLED_REASON = "crypto settles on CF Benchmarks RTI, not Coinbase spot; " \
                    "directional series settle on a 60-price RTI average"

  Result = Struct.new(:series, :product, :window_from, :window_to, :min, :max,
    :bars, :granularity, :markets, :opportunities, :error)

  # Kalshi series -> the Coinbase product whose price we read for it.
  PRODUCTS = {
    "KXBTCMINMON" => "BTC-USD",
    "KXBTCMAXY" => "BTC-USD",
    "KXETHMINMON" => "ETH-USD",
    "KXETHMAXY" => "ETH-USD"
  }.freeze

  def initialize(client: nil, max_contracts: 100, now: nil)
    @client = client || KalshiClient.from_env
    @max_contracts = max_contracts
    @now = now
  end

  def run
    # Guard sits BEFORE any client call: a disabled scanner that still fetches
    # is still burning rate limit and still depending on the wrong source.
    unless ENABLED
      return PRODUCTS.keys.map do |series|
        Result.new(series: series, markets: 0, opportunities: [],
          error: "disabled: #{DISABLED_REASON}")
      end
    end

    PRODUCTS.keys.map { |series| scan(series) }
  end

  private

  def scan(series)
    now = @now || Time.now.utc
    rows = @client.series_markets(series)
    return Result.new(series: series, markets: 0, opportunities: []) if rows.empty?

    # Every market in the series shares an issuance window, so the extremes are
    # fetched once rather than per strike.
    from = Time.parse(rows.first["open_time"].to_s)
    extremes = PriceExtremes.for_window(PRODUCTS.fetch(series), from: from, to: now)

    opportunities = rows.filter_map do |row|
      market = RatchetRegistry.build(row)
      next unless market

      observed = (RatchetRegistry.observable_for(row["ticker"]) == :window_min_usd) ? extremes[:min] : extremes[:max]
      next if observed.nil?

      resting = row["yes_ask_size_fp"].to_f.floor
      found = Opportunity.find(
        market: market,
        observed: observed,
        bid_cents: (row["yes_bid_dollars"].to_f * 100).round,
        ask_cents: (row["yes_ask_dollars"].to_f * 100).round,
        contracts: [resting, @max_contracts].min
      )
      next unless found

      found.merge(observed: observed, threshold: market.threshold,
        market_pct: found[:price_cents], sub_title: row["yes_sub_title"])
    end

    Result.new(series: series, product: PRODUCTS.fetch(series),
      window_from: from, window_to: now, min: extremes[:min], max: extremes[:max],
      bars: extremes[:bars], granularity: extremes[:granularity],
      markets: rows.size, opportunities: opportunities)
  rescue => e
    Result.new(series: series, markets: 0, opportunities: [], error: "#{e.class}: #{e.message}")
  end
end
