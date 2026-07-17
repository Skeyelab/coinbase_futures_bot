# frozen_string_literal: true

module Sentiment
  class MultiSourceAggregator
    include SentryServiceTracking

    def initialize(logger: Rails.logger)
      @logger = logger
      @clients = build_clients
    end

    # Fetch from all enabled sources and return combined results
    def fetch_all_sources(max_pages: 2)
      all_events = []
      successful_sources = []
      failed_sources = []

      @clients.each do |client|
        next unless client.enabled?

        begin
          @logger.info("Fetching from #{client.source_name}")
          events = client.fetch_recent(max_pages: max_pages)
          all_events.concat(events)
          successful_sources << client.source_name
          @logger.info("#{client.source_name}: fetched #{events.size} events")
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
              failed_sources: failed_sources
            })
            Sentry.capture_exception(e)
          end
        end
      end

      @logger.info("Multi-source fetch complete: #{all_events.size} total events from #{successful_sources.size}/#{@clients.size} sources")

      # Track aggregation success
      SentryHelper.add_breadcrumb(
        message: "Multi-source news aggregation completed",
        category: "sentiment",
        level: "info",
        data: {
          total_events: all_events.size,
          successful_sources: successful_sources,
          failed_sources: failed_sources,
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

    # Oil/energy news feeds. Verified active RSS sources for crude sentiment;
    # each is polite at the existing fetch cadence and needs no API token.
    OIL_FEEDS = [
      {url: "https://oilprice.com/rss/main", source_name: "oilprice_rss"},
      {url: "https://www.investing.com/rss/news_11.rss", source_name: "investing_commodities_rss"},
      {url: "https://www.eia.gov/rss/todayinenergy.xml", source_name: "eia_today_in_energy_rss"}
    ].freeze

    def build_clients
      [
        CryptoPanicClient.new,
        CoindeskRssClient.new,
        CointelegraphRssClient.new,
        *OIL_FEEDS.map { |feed| GenericRssClient.new(**feed, logger: @logger) }
      ]
    end
  end
end
