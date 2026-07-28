# frozen_string_literal: true

module Sentiment
  class MultiSourceAggregator
    include SentryServiceTracking

    def initialize(logger: Rails.logger, clients: nil)
      @logger = logger
      @clients = clients || build_clients
    end

    # Fetch from all enabled sources and return combined results
    def fetch_all_sources(max_pages: 2)
      all_events = []
      successful_sources = []
      # A source that returns zero events is NOT a success. Only a raised
      # exception used to count as failure, so cryptopanic sat in
      # successful_sources on every run it ever made while producing nothing —
      # the completion log read "9/9 sources" and Sentry never heard about it
      # (issue #550). Empty is tracked separately so "working" and "broken but
      # quiet" stop being the same observation.
      empty_sources = []
      failed_sources = []

      @clients.each do |client|
        next unless client.enabled?

        begin
          @logger.info("Fetching from #{client.source_name}")
          events = client.fetch_recent(max_pages: max_pages)
          all_events.concat(events)
          if events.empty?
            empty_sources << client.source_name
            @logger.warn("#{client.source_name}: returned 0 events — degraded, not counted as delivering")
          else
            successful_sources << client.source_name
            @logger.info("#{client.source_name}: fetched #{events.size} events")
          end
        rescue => e
          @logger.error("#{client.source_name} failed: #{e.class} #{e.message}")
          failed_sources << client.source_name

          # Track individual source failures
          Sentry.with_scope do |scope|
            scope.set_tag("service", "multi_source_aggregator")
            scope.set_tag("failed_source", client.source_name)
            scope.set_context("aggregation", {
              total_sources: @clients.size,
              successful_sources: successful_sources,
              empty_sources: empty_sources,
              failed_sources: failed_sources
            })
            Sentry.capture_exception(e)
          end
        end
      end

      @logger.info("Multi-source fetch complete: #{all_events.size} total events; " \
                   "#{successful_sources.size}/#{@clients.size} delivering, " \
                   "#{empty_sources.size} empty#{" (#{empty_sources.join(", ")})" if empty_sources.any?}, " \
                   "#{failed_sources.size} failed")

      # Track aggregation success
      SentryHelper.add_breadcrumb(
        message: "Multi-source news aggregation completed",
        category: "sentiment",
        level: "info",
        data: {
          total_events: all_events.size,
          successful_sources: successful_sources,
          empty_sources: empty_sources,
          failed_sources: failed_sources,
          # Delivering / configured. Previously this counted an empty source as
          # a success, so the rate could read 1.0 while a source produced nothing.
          success_rate: successful_sources.size.to_f / @clients.size
        }
      )

      all_events
    end

    # Get status of all configured sources
    def source_status
      @clients.map do |client|
        {
          name: client.source_name,
          enabled: client.enabled?,
          class: client.class.name
        }
      end
    end

    private

    # RSS feeds come from config/sentiment_sources.yml (via SourceConfig) so a
    # new feed is a config edit, not a code change. The token-based crypto
    # clients stay explicit as they have bespoke fetch logic.
    def build_clients
      rss_clients = SourceConfig.default.rss_feeds.map do |feed|
        GenericRssClient.new(**feed, logger: @logger)
      end

      # CryptoPanicClient is NOT built — the code is fine, the PLAN is gone.
      #
      # CryptoPanic's docs: "The free Developer API plan is discontinued and will
      # be removed on April 1st, 2026." That date has passed. The documented base
      # is https://cryptopanic.com/api/<plan>/v2, which is exactly what API_BASE
      # targets, so the client would work again on a paid plan. Verified live
      # 2026-07-28: /api/developer/v2/posts/ -> 404, /api/v1/posts/ -> 403
      # ("no access to this endpoint" per their error table), and the public
      # /news/rss/ path serves HTML, not a feed — so there is no free fallback.
      #
      # It produced zero events for its entire life while reporting
      # enabled? == true, because `enabled?` only checks that a token is
      # PRESENT, not that it authenticates. Leaving it wired meant one
      # guaranteed empty source every cycle and an inflated source count.
      # Re-add if a paid plan is bought (issue #550).
      [
        CoindeskRssClient.new,
        CointelegraphRssClient.new,
        EiaInventoryClient.new(logger: @logger),
        *rss_clients
      ]
    end
  end
end
