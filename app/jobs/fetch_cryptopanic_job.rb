# frozen_string_literal: true

class FetchCryptopanicJob < ApplicationJob
  queue_as :default

  def perform(max_pages: 2)
    client = Sentiment::CryptoPanicClient.new
    return unless client.enabled?

    events = client.fetch_recent(max_pages: max_pages)
    result = Sentiment::EventIngest.call(events)

    Rails.logger.info(
      "FetchCryptopanicJob: stored #{result.inserted} new events " \
      "(#{result.skipped} already seen)"
    )
  end
end
