# frozen_string_literal: true

require "net/http"
require "uri"
require "rexml/document"
require "digest"
require "time"

module Sentiment
  # RSS news client parameterized by feed URL and source name. Lets a new feed
  # (crypto or commodity) be added as configuration rather than a new class.
  class GenericRssClient < BaseNewsClient
    attr_reader :source_name

    def initialize(url:, source_name:, logger: Rails.logger)
      super(logger: logger)
      @rss_url = url
      @source_name = source_name
    end

    def enabled?
      @rss_url.present?
    end

    def fetch_recent(max_pages: 2)
      response = fetch_with_redirects(@rss_url)

      unless response.is_a?(Net::HTTPSuccess)
        @logger.error("#{@source_name}: HTTP error #{response.code}: #{response.message}")
        return []
      end

      doc = REXML::Document.new(response.body)
      items = []
      doc.elements.each("rss/channel/item") do |item|
        normalized = normalize_rss_item(item)
        items.concat(normalized) if normalized.any?
      end
      doc.elements.each("feed/entry") do |entry|
        normalized = normalize_atom_entry(entry)
        items.concat(normalized) if normalized.any?
      end

      @logger.info("#{@source_name}: fetched #{items.size} events")
      items
    rescue REXML::ParseException => e
      @logger.error("#{@source_name} XML parse error: #{e.message}")
      handle_error(e, "xml_parse_error")
      []
    rescue => e
      @logger.error("#{@source_name} fetch failed: #{e.class} #{e.message}")
      handle_error(e, "unexpected_error")
      []
    end

    private

    def fetch_with_redirects(url, limit = 5)
      raise "Too many redirects" if limit == 0

      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true if uri.scheme == "https"

      request = Net::HTTP::Get.new(uri)
      request["User-Agent"] = "FuturesBot/1.0"

      response = http.request(request)

      case response
      when Net::HTTPRedirection
        location = response["location"]
        location = URI.join(uri.to_s, location).to_s if location.start_with?("/")
        fetch_with_redirects(location, limit - 1)
      else
        response
      end
    end

    def normalize_rss_item(item)
      normalize_fields(
        title: item.elements["title"]&.text.to_s,
        url: item.elements["link"]&.text.to_s,
        pub_date: item.elements["pubDate"]&.text.to_s,
        description: item.elements["description"]&.text.to_s
      )
    end

    def normalize_fields(title:, url:, pub_date:, description:)
      return [] if contentless?(title, description)

      published_at = parse_timestamp(pub_date)
      content_text = "#{title} #{description}"
      symbols = extract_crypto_symbols(content_text)

      symbols.map do |symbol|
        {
          source: @source_name,
          symbol: symbol,
          url: url.presence,
          title: title.presence,
          published_at: published_at,
          raw_text_hash: generate_content_hash(url, title, symbol),
          meta: {
            description: description,
            pub_date_original: pub_date,
            content_preview: content_text[0..200]
          }
        }
      end
    end

    # Atom says the same things as RSS under different names: entry/summary
    # instead of item/description, updated instead of pubDate, and the URL in a
    # link element's href attribute rather than its text. Reshaped here so both
    # feed dialects converge on one normalizer.
    def normalize_atom_entry(entry)
      link = entry.elements["link"]
      normalize_fields(
        title: entry.elements["title"]&.text.to_s,
        url: (link&.attributes&.[]("href") || link&.text).to_s,
        pub_date: (entry.elements["updated"] || entry.elements["published"])&.text.to_s,
        description: (entry.elements["summary"] || entry.elements["content"])&.text.to_s
      )
    end

    # Feeds that synthesize a stand-in title for a body-less post. trumpstruth.org
    # emits "[No Title] - Post from July 28, 2026" for Trump's image-only and
    # re-truth posts; the body on those is literally "<p></p>".
    PLACEHOLDER_TITLE = /\A\s*\[\s*no title\s*\]/i

    # An item with no words of its own has nothing for the lexicon scorer to read
    # and nothing for the keyword router to match, so storing it can only produce
    # a permanently untagged row. Worse than useless: the ingest rate is what
    # OperatorSnapshot checks against SENTIMENT_UNDERSAMPLED_PER_HR, so a feed
    # that is 60% empty posts reports itself as healthy on volume it cannot score.
    #
    # A real headline with an empty body is still ingested — the title alone is
    # scorable. Only the placeholder-plus-empty-body combination is dropped.
    def contentless?(title, description)
      return false if strip_markup(description).present?

      title.blank? || PLACEHOLDER_TITLE.match?(title)
    end

    def strip_markup(html)
      html.to_s.gsub(/<[^>]*>/, " ").gsub(/&(?:[a-z]+|#\d+);/i, " ").strip
    end

    def handle_error(exception, error_type)
      Sentry.with_scope do |scope|
        scope.set_tag("service", @source_name)
        scope.set_tag("operation", "fetch_recent")
        scope.set_tag("error_type", error_type)
        scope.set_context("api_call", {rss_url: @rss_url})
        Sentry.capture_exception(exception)
      end
    end
  end
end
