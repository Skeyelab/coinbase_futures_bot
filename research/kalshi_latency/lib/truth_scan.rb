require_relative "truth_social_source"
require_relative "count_market"
require_relative "kalshi_client"
require_relative "opportunity"

# The Truth Social post-count ratchet as a continuous scan family: counts the
# market week from Roll Call's tracker (the source the Kalshi rules name) and
# prices every KXTRUTHSOCIAL contract against it.
#
# The count is cached for count_ttl seconds: posts arrive over hours, and
# re-paging Roll Call every collector cycle would be discourteous for zero
# information. Kalshi quotes are fresh every cycle.
class TruthScan
  Result = Struct.new(:series, :observed_count, :markets, :opportunities, :error)

  SERIES = "KXTRUTHSOCIAL".freeze
  DEFAULT_COUNT_TTL = 3600
  # The market week under calibration. The rules text gives no timezone, so
  # this stays an explicit constant to be moved deliberately each week, not a
  # derivation that guesses one.
  DEFAULT_WEEK_START = "2026-08-02 00:00:00".freeze

  def initialize(source: nil, client: nil, week_start: ENV.fetch("TRUTH_WEEK_START", DEFAULT_WEEK_START),
    count_ttl: DEFAULT_COUNT_TTL, max_contracts: 25, clock: -> { Time.now.to_i })
    @source = source || TruthSocialSource.new
    @client = client || KalshiClient.new
    @week_start = week_start
    @count_ttl = count_ttl
    @max_contracts = max_contracts
    @clock = clock
  end

  def run
    count = cached_count
    if count.nil?
      return [Result.new(series: SERIES, markets: 0, opportunities: [],
        error: "could not establish the week boundary — refusing to guess a count")]
    end

    rows = @client.series_markets(SERIES)
    opportunities = rows.filter_map { |row| opportunity_for(row, count) }

    [Result.new(series: SERIES, observed_count: count, markets: rows.size,
      opportunities: opportunities)]
  end

  private

  def cached_count
    now = @clock.call
    if @counted_at.nil? || now - @counted_at >= @count_ttl
      result = @source.ids_since(@week_start)
      @count = result && result[:ids].size
      # A failed count is not cached: retry next cycle rather than repeating
      # "no boundary" for an hour.
      @counted_at = result ? now : nil
    end
    @count
  end

  def opportunity_for(row, count)
    market = CountMarket.from_api(row)
    return nil unless market

    bid = (row["yes_bid_dollars"].to_f * 100).round
    ask = (row["yes_ask_dollars"].to_f * 100).round
    resting = row["yes_bid_size_fp"].to_f.floor
    found = Opportunity.find(
      market: market, observed: count, bid_cents: bid, ask_cents: ask,
      contracts: [resting, @max_contracts].min
    )
    return nil unless found

    # market_pct feeds the same credibility gate as weather: a "settled" count
    # the book prices at 78c is a disagreement we are probably losing, not
    # free money. verified: Roll Call is the source the rules name.
    found.merge(market_pct: found[:price_cents], verified: true, observed_count: count)
  end
end
