require "net/http"
require "json"
require "uri"
require "rexml/document"
require "digest"

# Polls RSS feeds and records the moment WE first saw each headline.
#
# The honest caveat, and it matters for reading the results: RSS is slow. A
# headline can be minutes old by the time it appears in a feed. So our
# first-seen timestamp is a LATE bound on when the news broke, which biases
# every measurement AGAINST finding an edge — the market will look like it
# moved before we knew.
#
# That makes a positive result trustworthy and a negative result inconclusive.
# If the move duration turns out to be long, a real news feed only widens it.
class NewsFeed
  # Verified live 2026-08-04. Reuters, CNN and AP's public RSS are all dead or
  # blocked now; don't re-add them without checking.
  DEFAULT_FEEDS = [
    "https://feeds.bbci.co.uk/news/world/rss.xml",
    "https://feeds.npr.org/1001/rss.xml",
    "https://moxie.foxnews.com/google-publisher/latest.xml",
    "https://feeds.a.dj.com/rss/RSSWorldNews.xml",
    "https://www.cnbc.com/id/100003114/device/rss/rss.html",
    "https://feeds.content.dowjones.io/public/rss/mw_topstories",
    "https://feeds.washingtonpost.com/rss/politics"
  ].freeze

  def initialize(feeds: DEFAULT_FEEDS, logger: nil)
    @feeds = feeds
    @logger = logger
    @seen = {}
  end

  # Returns only headlines not seen before, stamped with first-seen time.
  def poll
    fresh = []

    @feeds.each do |url|
      items(url).each do |item|
        key = item[:guid]
        next if @seen.key?(key)

        @seen[key] = true
        fresh << item.merge(first_seen_at: Time.now.to_i)
      end
    rescue => e
      log("feed failed #{url}: #{e.class}: #{e.message}")
    end

    fresh
  end

  private

  def items(url)
    response = Net::HTTP.get_response(URI(url))
    return [] unless response.code == "200"

    doc = REXML::Document.new(response.body)
    doc.elements.to_a("//item").map do |item|
      title = text_of(item, "title")
      link = text_of(item, "link")

      {
        source: URI(url).host,
        title: title,
        link: link,
        published: text_of(item, "pubDate"),
        guid: Digest::SHA256.hexdigest("#{link}|#{title}")[0, 16]
      }
    end
  end

  def text_of(item, name)
    item.elements[name]&.text.to_s.strip
  end

  def log(message)
    @logger&.call("[news] #{message}")
  end
end
