require "json"
require "fileutils"

require_relative "weather_scan"

# Logs the settled-fact picture continuously so we can measure dwell time:
# how long a contract the weather has already decided stays quotable.
#
# Observations and quotes move at very different speeds. NWS publishes hourly,
# the book moves second to second, so polling them on one cadence would either
# hammer NWS for nothing or sample the book too slowly to time anything.
class WeatherCollector
  def initialize(data_dir:, quote_interval: 15, observation_ttl: 120, scan: nil, logger: nil)
    @data_dir = data_dir
    @quote_interval = quote_interval
    @observation_ttl = observation_ttl
    @logger = logger || ->(m) { warn("#{Time.now.utc.strftime("%H:%M:%S")} #{m}") }
    @scan = scan || WeatherScan.new
    @running = true

    FileUtils.mkdir_p(@data_dir)
  end

  def run
    trap("INT") { @running = false }
    trap("TERM") { @running = false }

    log("collecting into #{@data_dir}")

    while @running
      began = Time.now.to_f

      begin
        cycle
      rescue => e
        log("scan failed: #{e.class}: #{e.message}")
      end

      nap(@quote_interval - (Time.now.to_f - began))
    end

    log("stopped")
  end

  private

  def cycle
    at = Time.now.utc.to_i

    @scan.run.each do |result|
      if result.error
        log("#{result.city}: #{result.error}")
        next
      end

      write("weather", {
        at: at,
        city: result.city,
        station: result.station,
        local_date: result.local_date.to_s,
        running_high: result.running_high,
        observed_at: result.observed_at&.to_i,
        obs_age_seconds: result.obs_age_seconds,
        markets: result.markets,
        opportunities: result.opportunities
      })

      result.opportunities.each do |o|
        log("OPPORTUNITY #{result.city} #{o[:ticker]} #{o[:side]} @#{o[:price_cents]}c net=#{o[:net_cents]}c")
      end
    end
  end

  def nap(seconds)
    remaining = seconds
    while @running && remaining > 0
      slice = [remaining, 0.5].min
      sleep(slice)
      remaining -= slice
    end
  end

  def write(stream, record)
    path = File.join(@data_dir, "#{stream}-#{Time.now.utc.strftime("%Y-%m-%d")}.jsonl")
    File.open(path, "a") { |f| f.puts(JSON.generate(record)) }
  end

  def log(message)
    @logger.call(message)
  end
end
