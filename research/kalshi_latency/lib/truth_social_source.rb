require "net/http"
require "time"
require "uri"
require "base64"
require "json"

# Reads Roll Call's Trump post tracker at trumpstruth.org.
#
# This IS the settlement source named in the KXTRUTHSOCIAL rules, not a proxy
# for it. Reading Truth Social directly would be the same mistake as reading
# Coinbase spot for a market that settles on CF Benchmarks RTI.
#
# PAGINATION, learned the hard way:
#   - /feed is XML but holds only ~100 items (~28 hours) with no pagination.
#   - start_date / end_date on the HTML page are SILENTLY IGNORED. Every date
#     returns byte-identical output, which looks like it works until you notice
#     four different days reporting the same id range.
#   - The site's own next-cursor advances exactly one page then repeats itself.
#   - CONSTRUCTED cursors work. The cursor is base64 JSON carrying a timestamp,
#     and asking for an arbitrary one returns the posts older than it.
#
# Posts carry sequential integer ids, so a count over a window is the set of
# ids newer than the last id before the window opened.
class TruthSocialSource
  HOST = "trumpstruth.org"
  USER_AGENT = ENV.fetch("RESEARCH_USER_AGENT", "kalshi-latency-research (dahl.eric@gmail.com)")
  PER_PAGE = 100

  # The cursor is base64 JSON. _pointsToNextItems means "older than this".
  def self.cursor_for(timestamp)
    Base64.strict_encode64({status_created_at: timestamp, _pointsToNextItems: true}.to_json)
  end

  # Status ids out of a page of HTML. Permalinks appear more than once per post
  # (permalink plus share link), so uniqueness is not optional.
  def self.status_ids(html)
    html.to_s.scan(%r{trumpstruth\.org/statuses/(\d+)}).flatten.map(&:to_i).uniq.sort
  end

  def initialize(logger: nil)
    @logger = logger
  end

  # One page: the newest posts, or those older than `before` when given.
  def page(before: nil)
    query = {sort: "desc", per_page: PER_PAGE, removed: "include"}
    query[:cursor] = self.class.cursor_for(before) if before

    self.class.status_ids(get(query))
  end

  # Every id newer than the last one preceding `since`.
  #
  # Walks day-sized cursor steps backwards rather than trusting the site's
  # next-cursor, which repeats. Returns nil when the boundary cannot be
  # established, because a count with an unknown start is worse than no count.
  def ids_since(since, steps: 8, step_seconds: 86_400)
    boundary = page(before: since).max
    return nil if boundary.nil?

    collected = page
    cursor_time = Time.now.utc
    steps.times do
      break if cursor_time.to_i <= Time.parse(since).to_i

      collected |= page(before: cursor_time.strftime("%Y-%m-%d %H:%M:%S"))
      cursor_time -= step_seconds
    end

    {boundary: boundary, ids: collected.select { |i| i > boundary }.sort}
  end

  private

  def get(query)
    uri = URI("https://#{HOST}/")
    uri.query = URI.encode_www_form(query)
    http = Net::HTTP.new(HOST, 443)
    http.use_ssl = true
    http.open_timeout = 10
    http.read_timeout = 25

    response = http.get(uri.request_uri, {"User-Agent" => USER_AGENT})
    return "" unless response.code == "200"

    response.body.to_s
  rescue => e
    @logger&.call("[trumpstruth] #{e.class}: #{e.message}")
    ""
  end
end
