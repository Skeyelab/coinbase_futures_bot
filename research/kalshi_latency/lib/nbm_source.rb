require "json"
require "net/http"
require "uri"
require "time"
require "tzinfo"

# Latest NBM NBE point guidance for a station, via the IEM MOS archive
# (the ~hourly ingest lag there is fine at 24h lead; a live re-quoter would
# read the NBE text product from NWS instead).
#
# Only the 00Z-valid row of a run carries txn (forecast daytime max) and xnd
# (the NBM ensemble SD of it) — and 00Z UTC on date D+1 is the evening of
# date D in US timezones, so it covers D's daytime high.
class NbmSource
  URL = "https://mesonet.agron.iastate.edu/api/1/mos.json".freeze

  def initialize(fetch: nil)
    @fetch = fetch || method(:http_fetch)
  end

  def forecast_for(station, local_date, time_zone:)
    tz = TZInfo::Timezone.get(time_zone)

    @fetch.call(station).each do |row|
      next if row["txn"].nil?

      valid = Time.parse("#{row["ftime_utc"]}Z")
      next unless valid.hour.zero? # utc
      next unless tz.to_local(valid).to_date == local_date

      runtime = Time.parse("#{row["runtime_utc"]}Z")
      return {
        txn: row["txn"], xnd: row["xnd"],
        lead_hours: (valid - runtime) / 3600.0,
        runtime: row["runtime_utc"]
      }
    end
    nil
  end

  private

  def http_fetch(station)
    uri = URI("#{URL}?station=#{station}&model=NBE")
    response = Net::HTTP.get_response(uri)
    return [] unless response.code == "200"

    JSON.parse(response.body)["data"] || []
  end
end
