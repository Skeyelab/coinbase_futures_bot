# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'digest'
require 'time'

module Sentiment
  class CryptoPanicClient < BaseNewsClient
    include SentryServiceTracking

    API_BASE = 'https://cryptopanic.com/api/developer/v2'

    def initialize(token: ENV['CRYPTOPANIC_TOKEN'], base_url: ENV['CRYPTOPANIC_BASE_URL'], logger: Rails.logger)
      super(logger: logger)
      @token = token
      @base_url = base_url.presence || API_BASE
    end

    def enabled?
      token_present = @token.to_s.strip != ''
      @logger.warn('CryptoPanic token not configured - set CRYPTOPANIC_TOKEN environment variable') unless token_present
      token_present
    end

    # Fetch recent posts (1-2 pages) and normalize to internal event hashes
    # Returns array of hashes with keys matching SentimentEvent columns
    def fetch_recent(max_pages: 2, public_only: true)
      return [] unless enabled?

      @logger.debug("CryptoPanic: Fetching up to #{max_pages} pages from #{@base_url}")

      results = []
      page = 1
      while page <= max_pages
        params = { auth_token: @token, page: page }
        params[:public] = true if public_only
        # Try to get the most recent posts by removing any filters that might limit results

        @logger.debug("CryptoPanic: Requesting page #{page} with params: #{params.except(:auth_token).merge(auth_token: '[REDACTED]')}")

        # Build the full URL with query parameters
        query_string = URI.encode_www_form(params)
        full_url = "#{@base_url}/posts/?#{query_string}"
        uri = URI(full_url)

        @logger.debug("CryptoPanic: Full URL: #{full_url}")

        # Make the HTTP request
        response = Net::HTTP.get_response(uri)

        @logger.debug("CryptoPanic: Response status: #{response.code}, body length: #{response.body.length}")

        unless response.is_a?(Net::HTTPSuccess)
          @logger.error("CryptoPanic: HTTP error #{response.code}: #{response.message}")
          @logger.debug("CryptoPanic: Response body start: #{response.body[0..200]}")
          return []
        end

        unless response.content_type&.include?('application/json')
          @logger.error("CryptoPanic: Expected JSON response, got #{response.content_type}")
          @logger.debug("CryptoPanic: Response body start: #{response.body[0..200]}")
          return []
        end

        body = JSON.parse(response.body)

        if body['status'] == 'api_error'
          @logger.error("CryptoPanic API error: #{body['info']}")
          return []
        end

        Array(body['results']).each do |item|
          normalized = normalize_item(item)
          results.concat(normalized) if normalized.any?
        end

        # Debug: Show the published dates of articles on this page
        page_dates = Array(body['results']).filter_map do |item|
          Time.parse(item['published_at'])
        rescue StandardError
          nil
        end
        @logger.debug("CryptoPanic: Page #{page} returned #{Array(body['results']).size} items")
        @logger.debug("CryptoPanic: Page #{page} date range: #{page_dates.min} to #{page_dates.max}") if page_dates.any?
        break unless body['next']

        page += 1
      end

      pages_fetched = page - 1
      @logger.info("CryptoPanic: Successfully fetched #{results.size} events from #{pages_fetched} pages")

      # Track successful sentiment data fetching
      SentryHelper.add_breadcrumb(
        message: 'CryptoPanic data fetched successfully',
        category: 'sentiment',
        level: 'info',
        data: {
          service: 'cryptopanic',
          events_count: results.size,
          pages_fetched: page - 1
        }
      )

      results
    rescue Net::HTTPError => e
      @logger.error("CryptoPanic HTTP error: #{e.class} #{e.message}")

      # Track HTTP errors separately
      Sentry.with_scope do |scope|
        scope.set_tag('service', 'cryptopanic')
        scope.set_tag('operation', 'fetch_recent')
        scope.set_tag('error_type', 'http_error')

        scope.set_context('api_call', {
                            base_url: @base_url,
                            max_pages: max_pages,
                            current_page: page,
                            has_token: @token.present?
                          })

        Sentry.capture_exception(e)
      end

      []
    rescue JSON::ParserError => e
      @logger.error("CryptoPanic JSON parse error: #{e.message}")

      # Track JSON parsing errors
      Sentry.with_scope do |scope|
        scope.set_tag('service', 'cryptopanic')
        scope.set_tag('operation', 'parse_response')
        scope.set_tag('error_type', 'json_parse_error')

        Sentry.capture_exception(e)
      end

      []
    rescue StandardError => e
      @logger.error("CryptoPanic fetch failed: #{e.class} #{e.message}")
      @logger.debug("Full error: #{e.backtrace.first(5).join('\n')}")

      # Track unexpected errors
      Sentry.with_scope do |scope|
        scope.set_tag('service', 'cryptopanic')
        scope.set_tag('operation', 'fetch_recent')
        scope.set_tag('error_type', 'unexpected_error')

        scope.set_context('api_call', {
                            base_url: @base_url,
                            max_pages: max_pages,
                            has_token: @token.present?
                          })

        Sentry.capture_exception(e)
      end

      []
    end

    def source_name
      'cryptopanic'
    end

    private

    # Returns array because a post can map to multiple symbols
    def normalize_item(item)
      title = item['title'].to_s
      url = item['url'].to_s
      published_at = begin
        Time.parse(item['published_at'])
      rescue StandardError
        Time.now.utc
      end
      votes = item['votes'] || {}
      currencies = Array(item['currencies']).map { |c| c['code'].to_s.upcase }.uniq

      symbols = map_currencies_to_symbols(currencies)
      symbols = [nil] if symbols.empty?

      raw_text_hash = Digest::SHA256.hexdigest([url, title].join('|'))

      symbols.map do |sym|
        {
          source: 'cryptopanic',
          symbol: sym,
          url: url.presence,
          title: title.presence,
          published_at: published_at,
          raw_text_hash: raw_text_hash,
          meta: {
            votes: votes,
            currencies: currencies,
            cryptopanic_id: item['id'],
            kind: item['kind'],
            domain: item['domain'],
            source_title: item.dig('source', 'title')
          }
        }
      end
    end

    def map_currencies_to_symbols(codes)
      Array(codes).filter_map do |code|
        case code
        when 'BTC' then 'BTC-USD'
        when 'ETH' then 'ETH-USD'
        end
      end.uniq
    end
  end
end
