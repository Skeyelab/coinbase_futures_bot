# frozen_string_literal: true

module Sentiment
  # The single write path for sentiment_events.
  #
  # The fetch jobs previously called SentimentEvent.upsert per item, which is
  # ON CONFLICT DO UPDATE across every column passed — including
  # created_at: Time.now.utc. RSS feeds re-serve the same items for as long as
  # they sit in the feed window, so every poll rewrote the ingestion timestamp
  # of rows already stored. That defeats #446, which exists precisely so
  # created_at means "when we first saw this": inflow metrics counted re-polls
  # as fresh arrivals, and any per-day history drifted forward as old rows were
  # dragged to now.
  #
  # An already-stored event is left completely alone here — not rewritten with
  # identical values, not touched at all — so created_at keeps meaning first
  # sight and downstream scoring survives a re-poll. Skipping the write also
  # stops the insert attempt that a conflicting upsert would otherwise make,
  # which was burning a sequence value per duplicate (~832 consumed IDs per
  # surviving row).
  class EventIngest
    Result = Struct.new(:inserted, :skipped)

    INSERT_COLUMNS = %i[source symbol url title published_at raw_text_hash meta].freeze

    def self.call(events, now: Time.now.utc)
      new(events, now: now).call
    end

    def initialize(events, now: Time.now.utc)
      @events = Array(events)
      @now = now
    end

    def call
      candidates = dedupe_within_batch(@events)
      fresh = candidates.reject { |attrs| stored.include?(key_for(attrs)) }

      SentimentEvent.insert_all(fresh.map { |attrs| row_for(attrs) }) if fresh.any?

      Result.new(fresh.size, @events.size - fresh.size)
    end

    private

    # insert_all raises when one batch carries the same unique key twice, which
    # happens whenever an article is served by two pages of the same feed.
    def dedupe_within_batch(events)
      events.uniq { |attrs| key_for(attrs) }
    end

    # One round trip for the whole batch. The pair filter is applied in Ruby
    # because the SQL predicate is a cross product of the two column lists.
    def stored
      @stored ||= begin
        keys = dedupe_within_batch(@events).map { |attrs| key_for(attrs) }
        return Set.new if keys.empty?

        SentimentEvent
          .where(source: keys.map(&:first).uniq, raw_text_hash: keys.map(&:last).uniq)
          .pluck(:source, :raw_text_hash)
          .to_set
      end
    end

    def key_for(attrs)
      [attrs[:source].to_s, attrs[:raw_text_hash].to_s]
    end

    def row_for(attrs)
      attrs.slice(*INSERT_COLUMNS).merge(created_at: @now, updated_at: @now)
    end
  end
end
