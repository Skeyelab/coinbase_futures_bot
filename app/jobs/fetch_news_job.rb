# frozen_string_literal: true

# New multi-source news fetching job
class FetchNewsJob < ApplicationJob
  queue_as :default

  def perform(max_pages: 2, sources: :all)
    aggregator = Sentiment::MultiSourceAggregator.new

    # For now, always fetch from all sources
    # Future: could support fetching from specific sources only
    events = aggregator.fetch_all_sources(max_pages: max_pages)

    result = Sentiment::EventIngest.call(events)

    # Log what was actually stored, not what was fetched: feeds re-serve the
    # same items for as long as they sit in the window, so `events.size` is
    # dominated by repeats and reads as far more inflow than really arrived.
    Rails.logger.info(
      "FetchNewsJob: stored #{result.inserted} new events " \
      "(#{result.skipped} already seen) from multiple sources"
    )
  end
end
