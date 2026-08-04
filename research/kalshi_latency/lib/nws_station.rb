require "net/http"
require "json"
require "uri"
require "time"

require_relative "daily_high"

# Observations from a single NWS station.
#
# NWS asks for a contact address in the User-Agent and will throttle anonymous
# clients, so identify honestly.
class NwsStation
  HOST = "api.weather.gov".freeze
  USER_AGENT = ENV.fetch("NWS_USER_AGENT", "kalshi-latency-research (dahl.eric@gmail.com)")

  class RequestFailed < StandardError; end

  def initialize(station, time_zone:)
    @station = station
    @time_zone = time_zone
  end

  attr_reader :station, :time_zone

  # Recent observations, newest first, each with the temperature in F and the
  # time WE fetched it. fetched_at is what makes latency measurable: the gap
  # between an observation's own timestamp and when it became readable.
  def observations(limit: 24)
    fetched_at = Time.now.utc

    body = get("/stations/#{@station}/observations?limit=#{limit}")
    (body["features"] || []).map do |feature|
      props = feature["properties"]
      celsius = props.dig("temperature", "value")

      {
        at: Time.parse(props["timestamp"]).utc,
        temp_f: celsius && (celsius * 9.0 / 5.0 + 32.0).round(1),
        fetched_at: fetched_at
      }
    end
  end

  def running_high(local_date, limit: 24)
    DailyHigh.new(observations(limit: limit), time_zone: @time_zone).for_date(local_date)
  end

  private

  def get(path)
    http = Net::HTTP.new(HOST, 443)
    http.use_ssl = true
    http.open_timeout = 10
    http.read_timeout = 15

    response = http.get(path, {"User-Agent" => USER_AGENT})
    raise RequestFailed, "GET #{path} -> HTTP #{response.code}" unless response.code == "200"

    JSON.parse(response.body)
  end
end
