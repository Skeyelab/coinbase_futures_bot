require "json"
require "fileutils"
require "net/http"
require "uri"

require_relative "kalshi_client"
require_relative "release_detector"

# Records a scheduled release and the market's reaction to it on ONE clock.
#
# The whole experiment is a subtraction: t_market_reprices - t_number_published.
# Both sides therefore have to be stamped by the same process with sub-second
# precision, which is why this does not reuse the 5s collector. Two loops with
# independent clocks cannot measure a gap smaller than their jitter.
#
# Read-only: GETs the BLS release page and the Kalshi order book. No order path.
class ReleaseRecorder
  BLS_EMPSIT = "https://www.bls.gov/news.release/empsit.nr0.htm"
  USER_AGENT = ENV.fetch("RESEARCH_USER_AGENT", "kalshi-latency-research (dahl.eric@gmail.com)")

  def initialize(data_dir:, tickers:, release_url: BLS_EMPSIT, interval: 1.0,
    depth: 10, client: nil, logger: nil)
    @data_dir = data_dir
    @tickers = tickers
    @release_url = URI(release_url)
    @interval = interval
    @depth = depth
    @logger = logger || ->(m) { warn("#{stamp} #{m}") }
    @client = client || KalshiClient.from_env(logger: @logger)
    @running = true
    @baseline = nil

    FileUtils.mkdir_p(@data_dir)
  end

  def run(seconds:)
    trap("INT") { @running = false }
    trap("TERM") { @running = false }

    deadline = Time.now.to_f + seconds
    log("recording #{@tickers.size} tickers for #{seconds}s into #{@data_dir}")
    log("kalshi authenticated=#{@client.authenticated?}")

    tick = 0
    while @running && Time.now.to_f < deadline
      started = Time.now.to_f
      capture_release(started)
      capture_books(started)
      tick += 1
      log("tick #{tick} took #{((Time.now.to_f - started) * 1000).round}ms") if (tick % 30).zero?
      nap(@interval - (Time.now.to_f - started))
    end

    log("stopped after #{tick} ticks")
  end

  private

  # Sends its own request rather than sharing a connection with the book poller:
  # a slow BLS response must not delay the market snapshot beside it.
  def capture_release(at)
    http = Net::HTTP.new(@release_url.host, 443)
    http.use_ssl = true
    http.open_timeout = 3
    http.read_timeout = 5

    sent = Time.now.to_f
    response = http.get(@release_url.request_uri, {"User-Agent" => USER_AGENT, "Cache-Control" => "no-cache"})
    received = Time.now.to_f

    observed = ReleaseDetector.observe(response.body)
    changed = !@baseline.nil? && (observed[:payrolls] != @baseline[:payrolls] || observed[:digest] != @baseline[:digest])
    @baseline ||= observed

    if changed
      log("*** RELEASE CHANGED at #{Time.at(received).utc.iso8601} payrolls=#{observed[:payrolls]} ***")
      @baseline = observed
    end

    write("release", {
      at: at.round(3), sent_at: sent.round(3), received_at: received.round(3),
      status: response.code, payrolls: observed[:payrolls],
      unemployment: observed[:unemployment], digest: observed[:digest], changed: changed
    })
  rescue => e
    write("release", {at: at.round(3), error: e.class.to_s})
  end

  def capture_books(at)
    @tickers.each do |ticker|
      sent = Time.now.to_f
      book = @client.order_book(ticker, depth: @depth)
      next unless book

      write("book", {
        at: at.round(3), sent_at: sent.round(3), received_at: Time.now.to_f.round(3),
        ticker: ticker, bid: book.best_bid_cents, ask: book.best_ask_cents,
        bid_size: book.best_bid_size, ask_size: book.best_ask_size,
        bid_depth_5c: book.bid_depth_within(5), ask_depth_5c: book.ask_depth_within(5)
      })
    end
  rescue => e
    write("book", {at: at.round(3), error: e.class.to_s})
  end

  def nap(seconds)
    remaining = seconds
    while @running && remaining > 0
      slice = [remaining, 0.2].min
      sleep(slice)
      remaining -= slice
    end
  end

  def write(stream, record)
    path = File.join(@data_dir, "#{stream}-#{Time.now.utc.strftime("%Y-%m-%d")}.jsonl")
    File.open(path, "a") { |f| f.puts(JSON.generate(record)) }
  end

  def stamp = Time.now.utc.strftime("%H:%M:%S.%L")

  def log(message) = @logger.call(message)
end
