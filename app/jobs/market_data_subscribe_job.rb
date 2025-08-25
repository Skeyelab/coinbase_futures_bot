# frozen_string_literal: true

class MarketDataSubscribeJob < ApplicationJob
  queue_as :default

  def perform(product_ids)
    product_ids = Array(product_ids)
    # No need to check for PERP suffix since we don't support perpetual contracts
    MarketData::CoinbaseSpotSubscriber.new(product_ids: product_ids).start
  end
end
