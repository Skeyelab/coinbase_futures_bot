require_relative "storm_count_source"
require_relative "ratchet_registry"
require_relative "kalshi_client"
require_relative "opportunity"

# Named-storm and hurricane season totals against their Kalshi books.
#
# Same shape as WeatherScan and TruthScan: read a monotone public number, price
# every contract against it, and hand each finding the signals Credibility
# needs. The count comes from NHC, the source the rules name.
#
# Basin lives in the ticker (KXNAMEDSTORM-26DEC01EPACTOT-26), which is the only
# place it appears -- the strike carries the threshold, not the basin.
class StormScan
  Result = Struct.new(:series, :basin, :observed_count, :markets, :opportunities, :error)

  SERIES = %w[KXNAMEDSTORM KXHURRICANE].freeze
  BASIN_PATTERN = /(ATL|EPAC|CPAC)/

  def initialize(source: nil, client: nil, max_contracts: 25)
    @source = source || StormCountSource.new
    @client = client || KalshiClient.new
    @max_contracts = max_contracts
  end

  def run
    @source.observe!

    SERIES.flat_map do |series|
      rows = @client.series_markets(series, limit: 200)
      rows.group_by { |row| basin_of(row["ticker"]) }.map do |basin, basin_rows|
        next nil unless basin

        count = @source.count(basin)
        Result.new(series: series, basin: basin, observed_count: count,
          markets: basin_rows.size,
          opportunities: basin_rows.filter_map { |row| opportunity_for(row, count) })
      end.compact
    end
  rescue => e
    # Class only, never the message: an exception body on exo-mini is how a
    # credential reaches a journal.
    [Result.new(series: SERIES.first, markets: 0, opportunities: [], error: e.class.to_s)]
  end

  private

  def basin_of(ticker) = ticker.to_s[BASIN_PATTERN, 1]

  def opportunity_for(row, count)
    market = RatchetRegistry.build(row)
    return nil unless market

    bid = (row["yes_bid_dollars"].to_f * 100).round
    ask = (row["yes_ask_dollars"].to_f * 100).round
    resting = row["yes_bid_size_fp"].to_f.floor
    found = Opportunity.find(market: market, observed: count, bid_cents: bid,
      ask_cents: ask, contracts: [resting, @max_contracts].min)
    return nil unless found

    # NHC is the named source, so `verified` is true -- unlike the inferred
    # weather stations. Support is 1: there is one authority, and corroboration
    # is not a concept the storm feed offers.
    found.merge(market_pct: found[:price_cents], verified: true,
      peak_support: 1, observed_count: count)
  end
end
