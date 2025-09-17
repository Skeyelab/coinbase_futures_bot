# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'rexml/document'
require 'digest'
require 'time'

module Sentiment
  class CoindeskRssClient < BaseNewsClient
    RSS_URL = 'https://www.coindesk.com/arc/outboundfeeds/rss/'

    def initialize(rss_url: ENV['COINDESK_RSS_URL'], logger: Rails.logger)
      super(logger: logger)
      @rss_url = rss_url.presence || RSS_URL
    end

    def enabled?
      # RSS feeds don't need tokens, always enabled
      true
    end

    def source_name
      'coindesk_rss'
    end

    def fetch_recent(max_pages: 2)
      @logger.debug("CoinDesk RSS: Fetching from #{@rss_url}")

      response = fetch_with_redirects(@rss_url)

      unless response.is_a?(Net::HTTPSuccess)
        @logger.error("CoinDesk RSS: HTTP error #{response.code}: #{response.message}")
        @logger.debug("CoinDesk RSS: Response body: #{response.body[0..500]}")
        return []
      end

      @logger.debug("CoinDesk RSS: Response length: #{response.body.length}")
      @logger.debug("CoinDesk RSS: Content type: #{response.content_type}")

      doc = REXML::Document.new(response.body)
      items = []

      # Parse RSS items
      item_count = 0
      doc.elements.each('rss/channel/item') do |item|
        item_count += 1
        normalized = normalize_rss_item(item)
        items.concat(normalized) if normalized.any?
      end

      @logger.debug("CoinDesk RSS: Found #{item_count} XML items, normalized to #{items.size} events")

      @logger.info("CoinDesk RSS: Successfully fetched #{items.size} items")

      # Track successful data fetching
      SentryHelper.add_breadcrumb(
        message: 'CoinDesk RSS data fetched successfully',
        category: 'sentiment',
        level: 'info',
        data: {
          service: 'coindesk_rss',
          events_count: items.size
        }
      )

      items
    rescue Net::HTTPError => e
      @logger.error("CoinDesk RSS HTTP error: #{e.class} #{e.message}")
      handle_error(e, 'http_error')
      []
    rescue REXML::ParseException => e
      @logger.error("CoinDesk RSS XML parse error: #{e.message}")
      handle_error(e, 'xml_parse_error')
      []
    rescue StandardError => e
      @logger.error("CoinDesk RSS fetch failed: #{e.class} #{e.message}")
      handle_error(e, 'unexpected_error')
      []
    end

    private

    def fetch_with_redirects(url, limit = 5)
      raise 'Too many redirects' if limit == 0

      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true if uri.scheme == 'https'

      request = Net::HTTP::Get.new(uri)
      request['User-Agent'] = 'FuturesBot/1.0'

      response = http.request(request)

      case response
      when Net::HTTPRedirection
        location = response['location']
        # Handle relative redirects
        location = URI.join(uri.to_s, location).to_s if location.start_with?('/')
        @logger.debug("CoinDesk RSS: Following redirect to #{location}")
        fetch_with_redirects(location, limit - 1)
      else
        response
      end
    end

    def normalize_rss_item(item)
      title = item.elements['title']&.text.to_s
      url = item.elements['link']&.text.to_s
      pub_date = item.elements['pubDate']&.text.to_s
      description = item.elements['description']&.text.to_s

      published_at = parse_timestamp(pub_date)
      content_text = "#{title} #{description}"
      symbols = extract_crypto_symbols(content_text)
      raw_text_hash = generate_content_hash(url, title)

      symbols.map do |symbol|
        {
          source: source_name,
          symbol: symbol,
          url: url.presence,
          title: title.presence,
          published_at: published_at,
          raw_text_hash: raw_text_hash,
          meta: {
            description: description,
            pub_date_original: pub_date,
            content_preview: content_text[0..200]
          }
        }
      end
    end

    def handle_error(exception, error_type)
      Sentry.with_scope do |scope|
        scope.set_tag('service', 'coindesk_rss')
        scope.set_tag('operation', 'fetch_recent')
        scope.set_tag('error_type', error_type)

        scope.set_context('api_call', {
                            rss_url: @rss_url
                          })

        Sentry.capture_exception(exception)
      end
    end
  end
end
