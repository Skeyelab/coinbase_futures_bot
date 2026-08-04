require "date"
require "tzinfo"

require_relative "cities"
require_relative "kalshi_client"
require_relative "nws_station"
require_relative "temp_market"
require_relative "opportunity"

# Pairs each city's published running high against its live Kalshi book and
# reports what the weather has already settled that the market has not.
class WeatherScan
  Result = Struct.new(:city, :station, :local_date, :running_high, :observed_at,
    :obs_age_seconds, :markets, :opportunities, :error)

  def initialize(client: KalshiClient.new, now: nil, observation_ttl: 120)
    @client = client
    @fixed_now = now
    @observation_ttl = observation_ttl
    @observation_cache = {}
  end

  def run
    @now = @fixed_now || Time.now.utc
    Cities::ALL.map { |city| scan(city) }
  end

  private

  def scan(city)
    local_date = local_date_for(city[:time_zone])

    observations = cached_observations(city)
    high = DailyHigh.new(observations, time_zone: city[:time_zone]).for_date(local_date)
    latest = observations.reject { |o| o[:temp_f].nil? }.max_by { |o| o[:at] }

    markets = @client.temp_markets(city[:series], local_date)
    opportunities = markets.filter_map do |row|
      market = TempMarket.from_api(row)
      next unless market

      Opportunity.find(
        market: market,
        running_high: high,
        bid_cents: (row["yes_bid_dollars"].to_f * 100).round,
        ask_cents: (row["yes_ask_dollars"].to_f * 100).round
      )
    end

    Result.new(
      city: city[:label], station: city[:station], local_date: local_date,
      running_high: high, observed_at: latest && latest[:at],
      obs_age_seconds: latest && (@now - latest[:at]).to_i,
      markets: markets.size, opportunities: opportunities
    )
  rescue => e
    Result.new(city: city[:label], station: city[:station], markets: 0,
      opportunities: [], error: "#{e.class}: #{e.message}")
  end

  def local_date_for(zone_name)
    TZInfo::Timezone.get(zone_name).to_local(@now).to_date
  end

  # NWS publishes on an hourly cycle, so refetching every quote tick would be
  # abuse for no new information. The book still gets sampled every cycle.
  def cached_observations(city)
    entry = @observation_cache[city[:station]]
    return entry[:observations] if entry && (@now - entry[:at]) < @observation_ttl

    station = NwsStation.new(city[:station], time_zone: city[:time_zone])
    observations = station.observations
    @observation_cache[city[:station]] = {at: @now, observations: observations}
    observations
  end
end
