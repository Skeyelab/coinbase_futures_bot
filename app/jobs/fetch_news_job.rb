# frozen_string_literal: true

# New multi-source news fetching job
class FetchNewsJob < ApplicationJob
  queue_as :default

  def perform(max_pages: 2, sources: :all)
    aggregator = Sentiment::MultiSourceAggregator.new

    # For now, always fetch from all sources
    # Future: could support fetching from specific sources only
    events = aggregator.fetch_all_sources(max_pages: max_pages)

    # Store all events in database
    events.each do |attrs|
      SentimentEvent.upsert({
        source: attrs[:source],
        symbol: attrs[:symbol],
        url: attrs[:url],
        title: attrs[:title],
        published_at: attrs[:published_at],
        raw_text_hash: attrs[:raw_text_hash],
        meta: attrs[:meta],
        created_at: Time.now.utc,
        updated_at: Time.now.utc
      }, unique_by: :index_sentiment_events_on_source_and_raw_text_hash)
    end

    Rails.logger.info("FetchNewsJob: Stored #{events.size} events from multiple sources")
  end
end
