# frozen_string_literal: true

class FetchCandlesJob < ApplicationJob
  queue_as :default

  def perform(backfill_days: 7)
    rest = MarketData::CoinbaseRest.new
    # Ensure products are up to date
    rest.upsert_products

    TradingPair.enabled.find_each do |pair|
      start_time = [ last_candle_time(pair.product_id)&.+(1.hour), backfill_days.to_i.days.ago ].compact.min
      rest.upsert_1h_candles(product_id: pair.product_id, start_time: start_time, end_time: Time.now.utc)
      Rails.logger.info("[Candles] upserted 1h candles for #{pair.product_id} from #{start_time}")
    end
  end

  private

  def last_candle_time(product_id)
    Candle.where(symbol: product_id, timeframe: "1h").maximum(:timestamp)
  end
end