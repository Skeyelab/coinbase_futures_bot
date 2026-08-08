require "json"
require "net/http"
require "uri"
require "date"

# Cumulative snowfall from the NWS Climatological Report, via the IEM CLI
# archive -- the same product Kalshi settles temperature markets on, so the
# settlement basis is the one we already trust rather than a new unknown.
#
# Snow is a better ratchet than temperature: a season total can only RISE, and
# unlike a daily maximum it never resets at midnight. A contract asking "will
# Boston see more than 40 inches this season" is arithmetically settled the
# moment the 41st inch is reported, and stays settled.
#
# Built before the markets list (August). KXSNOW* series do not exist yet;
# ratchet_registry carries the mapping so the scan picks them up the day they
# appear.
class SnowSource
  IEM_CLI = "https://mesonet.agron.iastate.edu/json/cli.py".freeze
  MISSING = "M".freeze

  def initialize(fetch: nil)
    @fetch = fetch || method(:http_fetch)
    @cache = {}
  end

  # Season to date (the NWS snow season starts July 1). nil when no report in
  # the window carries a figure -- never 0, which would be a claim.
  def season_total(station, as_of: Date.today)
    latest(station, as_of, "snow_jul1")
  end

  def month_total(station, as_of: Date.today)
    latest(station, as_of, "snow_month")
  end

  # How many reports back this total. A cumulative figure standing on one
  # report gets doubted exactly like a lone temperature spike.
  def support(station, as_of: Date.today)
    usable(station, as_of, "snow_jul1").size
  end

  private

  # The most recent NON-MISSING value at or before as_of. A missing report is
  # carried through rather than read as zero: "M" is silence, and a cumulative
  # total that FALLS would refute contracts the season has already confirmed.
  def latest(station, as_of, field)
    usable(station, as_of, field).last&.fetch(field)
  end

  def usable(station, as_of, field)
    rows_for(station, as_of.year)
      .select { |r| Date.parse(r["valid"].to_s) <= as_of }
      .reject { |r| r[field].nil? || r[field] == MISSING }
      .sort_by { |r| r["valid"].to_s }
  rescue Date::Error
    []
  end

  # The snow season spans a year boundary, so December's season total lives in
  # one calendar file and February's in the next. Both are fetched and merged,
  # deduped by report date: the two files can overlap, and a doubled report
  # would inflate the support count that Credibility reads as corroboration.
  def rows_for(station, year)
    @cache[[station, year]] ||= [
      *(@fetch.call(station, year) || []),
      *(@fetch.call(station, year - 1) || [])
    ].uniq { |r| r["valid"].to_s }
  end

  def http_fetch(station, year)
    response = Net::HTTP.get_response(URI("#{IEM_CLI}?station=#{station}&year=#{year}"))
    return [] unless response.code == "200"

    JSON.parse(response.body)["results"] || []
  rescue
    []
  end
end
