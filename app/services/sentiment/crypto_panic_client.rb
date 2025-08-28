# frozen_string_literal: true

require "faraday"
require "json"
require "digest"
require "time"

module Sentiment
  class CryptoPanicClient
    API_BASE = "https://cryptopanic.com/api/v1"

    def initialize(token: ENV["CRYPTOPANIC_TOKEN"], base_url: ENV["CRYPTOPANIC_BASE_URL"], logger: Rails.logger)
      @token = token
      @logger = logger
      base_url = API_BASE if base_url.blank?
      @conn = Faraday.new(url: base_url) do |f|
        # Optional retry middleware; requires faraday-retry gem. Skip if unavailable.
        begin
          begin
            require "faraday/retry"
          rescue LoadError
            # ignore if gem not present
          end
          f.request :retry, max: 3, interval: 0.2, interval_randomness: 0.3, backoff_factor: 2
        rescue
          # retry middleware not available; proceed without it
        end
        f.response :raise_error
        f.adapter Faraday.default_adapter
      end
    end

    def enabled?
      token_present = @token.to_s.strip != ""
      @logger.warn("CryptoPanic token not configured - set CRYPTOPANIC_TOKEN environment variable") unless token_present
      token_present
    end

    # Fetch recent posts (1-2 pages) and normalize to internal event hashes
    # Returns array of hashes with keys matching SentimentEvent columns
    def fetch_recent(max_pages: 2, public_only: true)
      return [] unless enabled?

      @logger.debug("CryptoPanic: Fetching up to #{max_pages} pages from #{@conn.url_prefix}")

      results = []
      page = 1
      while page <= max_pages
        params = {auth_token: @token, page: page}
        params[:public] = true if public_only

        @logger.debug("CryptoPanic: Requesting page #{page} with params: #{params.except(:auth_token).merge(auth_token: "[REDACTED]")}")

        resp = @conn.get("/posts/", params)
        body = JSON.parse(resp.body)

        if body["status"] == "api_error"
          @logger.error("CryptoPanic API error: #{body["info"]}")
          return []
        end

        Array(body["results"]).each do |item|
          normalized = normalize_item(item)
          results.concat(normalized) if normalized.any?
        end

        @logger.debug("CryptoPanic: Page #{page} returned #{Array(body["results"]).size} items")
        break unless body["next"]

        page += 1
      end

      @logger.info("CryptoPanic: Successfully fetched #{results.size} events from #{page - 1} pages")
      results
    rescue => e
      @logger.error("CryptoPanic fetch failed: #{e.class} #{e.message}")
      @logger.error("Request URL: #{@conn.url_prefix}/posts/")
      @logger.debug("Full error: #{e.backtrace.first(5).join('\n')}")
      []
    end

    private

    # Returns array because a post can map to multiple symbols
    def normalize_item(item)
      title = item["title"].to_s
      url = item["url"].to_s
      published_at = begin
        Time.parse(item["published_at"])
      rescue
        Time.now.utc
      end
      votes = item["votes"] || {}
      currencies = Array(item["currencies"]).map { |c| c["code"].to_s.upcase }.uniq

      symbols = map_currencies_to_symbols(currencies)
      symbols = [nil] if symbols.empty?

      raw_text_hash = Digest::SHA256.hexdigest([url, title].join("|"))

      symbols.map do |sym|
        {
          source: "cryptopanic",
          symbol: sym,
          url: url.presence,
          title: title.presence,
          published_at: published_at,
          raw_text_hash: raw_text_hash,
          meta: {
            votes: votes,
            currencies: currencies,
            cryptopanic_id: item["id"],
            kind: item["kind"],
            domain: item["domain"],
            source_title: item.dig("source", "title")
          }
        }
      end
    end

    def map_currencies_to_symbols(codes)
      Array(codes).filter_map do |code|
        case code
        when "BTC" then "BTC-USD"
        when "ETH" then "ETH-USD"
        end
      end.uniq
    end
  end
end
