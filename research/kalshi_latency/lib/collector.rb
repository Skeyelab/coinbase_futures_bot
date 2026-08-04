require "json"
require "fileutils"

require_relative "kalshi_client"
require_relative "news_feed"

# Runs two independent samplers and appends both to daily JSONL files.
#
# Deliberately does NOT try to match news to markets while collecting. Matching
# is a judgement call that will change once we see the data, and baking it into
# the collector would mean throwing away two weeks of samples every time we
# change our minds. Log both streams raw; pair them in analysis.
class Collector
  def initialize(
    data_dir:,
    quote_interval: 5,
    news_interval: 30,
    rediscover_every: 3600,
    min_volume_24h: 1000,
    watchlist_size: 150,
    client: nil,
    news: nil,
    logger: nil
  )
    @data_dir = data_dir
    @quote_interval = quote_interval
    @news_interval = news_interval
    @rediscover_every = rediscover_every
    @min_volume_24h = min_volume_24h
    @watchlist_size = watchlist_size
    @logger = logger || ->(m) { warn("#{Time.now.utc.iso8601rfc} #{m}") }
    @client = client || KalshiClient.new(logger: @logger)
    @news = news || NewsFeed.new(logger: @logger)
    @running = true

    FileUtils.mkdir_p(@data_dir)
  end

  def run
    trap("INT") { @running = false }
    trap("TERM") { @running = false }

    threads = [Thread.new { quote_loop }, Thread.new { news_loop }]
    threads.each(&:join)
    log("stopped")
  end

  private

  def quote_loop
    tickers = []
    last_discovery = 0

    while @running
      began = Time.now.to_f

      begin
        if Time.now.to_i - last_discovery >= @rediscover_every
          picked = @client.discover(min_volume_24h: @min_volume_24h, limit: @watchlist_size)
          tickers = picked.map { |m| m[:ticker] }
          last_discovery = Time.now.to_i
          write("watchlist", {at: last_discovery, markets: picked})
          log("watching #{tickers.size} markets")
        end

        sampled_at = Time.now.to_i
        @client.quotes(tickers).each do |q|
          next if q[:bid_cents] <= 0 || q[:ask_cents] <= 0

          write("quotes", {
            at: sampled_at,
            ticker: q[:ticker],
            bid: q[:bid_cents].round(2),
            ask: q[:ask_cents].round(2),
            mid: ((q[:bid_cents] + q[:ask_cents]) / 2.0).round(3),
            bid_size: q[:bid_size],
            volume_24h: q[:volume_24h]
          })
        end
      rescue => e
        log("quote loop error: #{e.class}: #{e.message}")
      end

      nap(@quote_interval - (Time.now.to_f - began))
    end
  end

  def news_loop
    while @running
      began = Time.now.to_f

      begin
        @news.poll.each { |item| write("news", item) }
      rescue => e
        log("news loop error: #{e.class}: #{e.message}")
      end

      nap(@news_interval - (Time.now.to_f - began))
    end
  end

  # Sleep in short slices so Ctrl-C is responsive during a long interval.
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

class Time
  def iso8601rfc
    utc.strftime("%Y-%m-%dT%H:%M:%SZ")
  end
end
