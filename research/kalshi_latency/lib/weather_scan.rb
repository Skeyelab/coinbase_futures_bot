require "date"
require "tzinfo"

require_relative "cities"
require_relative "kalshi_client"
require_relative "nws_station"
require_relative "temp_market"
require_relative "low_temp_market"
require_relative "daily_low"
require_relative "opportunity"

# Pairs each city's published running high against its live Kalshi book and
# reports what the weather has already settled that the market has not.
class WeatherScan
  Result = Struct.new(:city, :station, :local_date, :running_high, :observed_at,
    :obs_age_seconds, :markets, :opportunities, :error, :kind,
    # The counterparty census. Opportunity.find returns nil when nothing rests
    # on the other side, so a bucket the arithmetic has KILLED but nobody bids
    # on never reaches the opportunity stream. Without these two counts, "zero
    # opportunities" cannot be told apart from "zero settled facts" -- and on
    # 2026-08-06 that difference was 12 dead buckets and no bidders.
    :dead_buckets, :dead_with_bid)

  def initialize(client: KalshiClient.new, now: nil, observation_ttl: 120, max_contracts: 25,
    station_source: nil)
    @max_contracts = max_contracts
    @station_source = station_source
    @client = client
    @fixed_now = now
    @observation_ttl = observation_ttl
    @observation_cache = {}
  end

  def run
    @now = @fixed_now || Time.now.utc
    Cities::ALL.map { |city| scan(city, :high) } +
      Cities::LOWS.map { |city| scan(city, :low) }
  end

  private

  def scan(city, kind = :high)
    local_date = local_date_for(city[:time_zone])

    observations = cached_observations(city)
    daily = (kind == :low) ? DailyLow.new(observations, time_zone: city[:time_zone])
                           : DailyHigh.new(observations, time_zone: city[:time_zone])
    high = daily.for_date(local_date)
    support = daily.support_for(local_date)
    latest = observations.reject { |o| o[:temp_f].nil? }.max_by { |o| o[:at] }

    markets = @client.temp_markets(city[:series], local_date)
    dead = 0
    dead_bid = 0

    opportunities = markets.filter_map do |row|
      market = (kind == :low) ? LowTempMarket.from_api(row) : TempMarket.from_api(row)
      next unless market

      # Size from what is actually resting, capped: the fee is charged once per
      # order, so a 1c edge is only worth taking once it is sized. Reporting a
      # single contract would hide every thin-but-real opportunity.
      resting = row["yes_bid_size_fp"].to_f.floor
      bid_cents = (row["yes_bid_dollars"].to_f * 100).round
      if market.status_given(high) == :refuted
        dead += 1
        dead_bid += 1 if bid_cents.positive?
      end
      found = Opportunity.find(
        market: market,
        observed: high,
        bid_cents: bid_cents,
        ask_cents: (row["yes_ask_dollars"].to_f * 100).round,
        contracts: [resting, @max_contracts].min
      )
      next unless found

      # Two sanity signals, because a settled-fact claim that the market
      # disputes is far more likely to be my error than free money.
      #
      # margin_f: how far the reading clears the rounding boundary. METAR is
      # whole Celsius, so a single 26.0C tick reads as 78.8F and sits 0.3F over
      # the 78.5 boundary -- enough for round() to say 79, not enough to trust.
      #
      # market_pct: what the book thinks. A contract I call worth zero that
      # still bids 78c is not an opportunity, it is a disagreement I am losing.
      found.merge(
        margin_f: margin_above_boundary(market, high, kind),
        peak_support: support,
        verified: city[:verified] != false,
        market_pct: found[:price_cents],
        # What was actually resting when we looked: the difference between an
        # opportunity and a rumour of one.
        bid_size: resting
      )
    end

    Result.new(
      city: city[:label], station: city[:station], local_date: local_date, kind: kind,
      running_high: high, observed_at: latest && latest[:at],
      obs_age_seconds: latest && (@now - latest[:at]).to_i,
      markets: markets.size, opportunities: opportunities,
      dead_buckets: dead, dead_with_bid: dead_bid
    )
  rescue => e
    Result.new(city: city[:label], station: city[:station], markets: 0,
      opportunities: [], error: "#{e.class}: #{e.message}")
  end

  # Distance past the whole-degree rounding boundary that settles this market
  # against us. nil when the market is not refuted by a cap.
  # How far the reading clears the whole-degree rounding boundary that settles
  # the contract against us. Direction matters: a high has to clear the cap
  # UPWARD, a low has to clear the floor DOWNWARD. Using the high formula on a
  # low market reports a comfortable margin on a reading that is nowhere near
  # settling anything.
  def margin_above_boundary(market, observed, kind)
    return nil if observed.nil?

    if kind == :low
      return nil if market.floor.nil?
      ((market.floor - 0.5) - observed).round(2)
    else
      return nil if market.cap.nil?
      (observed - (market.cap + 0.5)).round(2)
    end
  end

  def local_date_for(zone_name)
    TZInfo::Timezone.get(zone_name).to_local(@now).to_date
  end

  # NWS publishes on an hourly cycle, so refetching every quote tick would be
  # abuse for no new information. The book still gets sampled every cycle.
  def cached_observations(city)
    entry = @observation_cache[city[:station]]
    return entry[:observations] if entry && (@now - entry[:at]) < @observation_ttl

    station = @station_source ? @station_source.call(city)
      : NwsStation.new(city[:station], time_zone: city[:time_zone])
    observations = station.observations
    @observation_cache[city[:station]] = {at: @now, observations: observations}
    observations
  end
end
