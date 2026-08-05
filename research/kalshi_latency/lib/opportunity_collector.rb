require "json"
require "fileutils"

require_relative "weather_scan"
require_relative "touch_scan"
require_relative "truth_scan"

# Logs every scan cycle across every ratchet family, whether or not it found
# anything.
#
# EMPTY CYCLES ARE THE POINT. The funding gate needs an opportunity RATE, which
# is hits divided by scans. Logging only the hits makes the denominator
# invisible and turns "three opportunities" into a number that could mean three
# per hour or three per week. A scanner that records only its successes is how
# a strategy looks better than it is.
class OpportunityCollector
  def initialize(data_dir:, interval: 60, weather: nil, touch: nil, truth: nil, logger: nil, execution: nil)
    @data_dir = data_dir
    @interval = interval
    @logger = logger || ->(m) { warn("#{Time.now.utc.strftime("%H:%M:%S")} #{m}") }
    @weather = weather || WeatherScan.new
    @touch = touch || TouchScan.new
    # Roll Call is paged at most once an hour inside the scan; the collector
    # cycles it like any other family and the cache does the throttling.
    @truth = truth || TruthScan.new
    # Optional dry-run execution pipeline. nil means what it always meant:
    # observe and record, place nothing anywhere.
    @execution = execution
    @running = true

    FileUtils.mkdir_p(@data_dir)
  end

  def run(seconds: nil)
    trap("INT") { @running = false }
    trap("TERM") { @running = false }

    deadline = seconds ? Time.now.to_f + seconds : nil
    cycles = 0
    found = 0
    log("scanning every #{@interval}s into #{@data_dir}")

    while @running && (deadline.nil? || Time.now.to_f < deadline)
      began = Time.now.to_f
      found += cycle(cycles += 1)
      log("cycle #{cycles}: #{found} opportunities total") if (cycles % 30).zero?
      nap(@interval - (Time.now.to_f - began))
    end

    log("stopped after #{cycles} cycles, #{found} opportunities")
  end

  private

  def cycle(number)
    at = Time.now.utc.to_i
    hits = 0

    hits += record("weather", at, number, @weather.run.map { |r|
      {scope: r.city, markets: r.markets, error: r.error, opportunities: r.opportunities}
    })
    hits += record("touch", at, number, @touch.run.map { |r|
      {scope: r.series, markets: r.markets, error: r.error, opportunities: r.opportunities,
       observed_min: r.min, observed_max: r.max}
    })
    hits += record("truth", at, number, @truth.run.map { |r|
      {scope: r.series, markets: r.markets, error: r.error, opportunities: r.opportunities,
       observed_count: r.observed_count}
    })

    hits
  rescue => e
    write("cycle", {at: at, cycle: number, error: "#{e.class}: #{e.message}"})
    0
  end

  def record(family, at, number, scopes)
    total = scopes.sum { |s| s[:opportunities].to_a.size }

    # One row per cycle per family, always -- this is the denominator.
    write("cycle", {
      at: at, cycle: number, family: family,
      scopes: scopes.size,
      markets: scopes.sum { |s| s[:markets].to_i },
      # A deliberately disabled family is not a failure. Counting it as one
      # puts "140 errors" in a log someone scans at 6am and reads as broken.
      errors: scopes.count { |s| s[:error] && !s[:error].to_s.start_with?("disabled") },
      disabled: scopes.count { |s| s[:error].to_s.start_with?("disabled") },
      opportunities: total
    })

    scopes.each do |s|
      s[:opportunities].to_a.each do |o|
        write("opportunity", o.merge(at: at, cycle: number, family: family, scope: s[:scope]))
        log("OPPORTUNITY #{s[:scope]} #{o[:ticker]} #{o[:side]} #{o[:contracts]}@#{o[:price_cents]}c net=#{o[:net_cents]}c")
        intent = @execution&.sight(o, at: at)
        log("INTENT #{intent[:mode]} #{intent[:ticker]} #{intent[:action]} #{intent[:count]}@#{intent[:yes_price]}c") if intent
      end
    end

    total
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

  def log(message) = @logger.call(message)
end
