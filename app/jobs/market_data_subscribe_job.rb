# frozen_string_literal: true

class MarketDataSubscribeJob < ApplicationJob
  queue_as :default

  def perform(product_ids)
    product_ids = Array(product_ids)
    if product_ids.any? { |p| p.end_with?("-PERP") }
      MarketData::CoinbaseFuturesSubscriber.new(product_ids: product_ids).start
    else
      MarketData::CoinbaseSpotSubscriber.new(product_ids: product_ids).start
    end
  end
end
