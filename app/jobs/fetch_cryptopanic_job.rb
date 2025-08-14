# frozen_string_literal: true

class FetchCryptopanicJob < ApplicationJob
  queue_as :default

  def perform(max_pages: 1)
    client = Sentiment::CryptoPanicClient.new
    return unless client.enabled?

    events = client.fetch_recent(max_pages: max_pages)
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
  end
end
