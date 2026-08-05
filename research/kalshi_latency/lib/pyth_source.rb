require "json"
require "net/http"
require "uri"

# Latest Pyth oracle prices for the feeds Kalshi's 15-minute commodity
# markets settle on (issue #629). Hermes is public, free, keyless — the
# property that makes this measurable where the crypto touch family
# (CF Benchmarks RTI, unreadable) was not.
#
# Feed identities were verified against live Kalshi strikes 2026-08-05:
# Kalshi's rules say "Pyth GOLD / SILVER / PYTHOIL", which map to XAU/USD,
# XAG/USD and — the trap — USOILSPOT, not the stale PYTHOIL/USD index feed
# (last publish 128 days old) and not the WTI futures-month feeds.
class PythSource
  HERMES = "https://hermes.pyth.network/v2/updates/price/latest".freeze

  FEEDS = {
    "GOLD" => "765d2ba906dbc32ca17cc11f5310a89e9ee1f6420508c63861f2f8ba4ee34bb2",
    "SILVER" => "f2fb02c32b055c805e7238d628e5e9dadef274376114eb1f012337cabe93871e",
    "WTI" => "925ca92ff005ae943c158e3563f59698ce7e75c5a8c8dd43303a0a154887b3e6"
  }.freeze

  def initialize(fetch: nil)
    @fetch = fetch || method(:http_fetch)
  end

  # {"GOLD" => {price:, publish_time:}, ...} — only what the payload carried.
  # A blip returns {} and the collector records the gap rather than dying.
  def latest
    by_id = FEEDS.invert

    (@fetch.call["parsed"] || []).each_with_object({}) do |row, out|
      symbol = by_id[row["id"]]
      next unless symbol

      price = row["price"]
      out[symbol] = {
        price: price["price"].to_f * (10.0**price["expo"]),
        publish_time: price["publish_time"]
      }
    end
  rescue
    {}
  end

  private

  def http_fetch
    query = FEEDS.values.map { |id| "ids[]=#{id}" }.join("&")
    response = Net::HTTP.get_response(URI("#{HERMES}?#{query}"))
    return {} unless response.code == "200"

    JSON.parse(response.body)
  end
end
