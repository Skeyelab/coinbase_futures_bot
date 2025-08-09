class MarketDataSubscribeJob < ApplicationJob
  queue_as :default

  def perform(product_ids)
    MarketData::CoinbaseFuturesSubscriber.new(product_ids: product_ids).start
  end
end
