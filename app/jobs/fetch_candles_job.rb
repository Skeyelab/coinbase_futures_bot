# frozen_string_literal: true

class FetchCandlesJob < ApplicationJob
  queue_as :default

  SYMBOL = "BTC-USD"

  def perform(backfill_days: 7)
    rest = MarketData::CoinbaseRest.new
    start_time = [ last_candle_time&.+(1.hour), backfill_days.to_i.days.ago ].compact.min
    rest.upsert_1h_candles(product_id: SYMBOL, start_time: start_time, end_time: Time.now.utc)
    Rails.logger.info("[Candles] upserted 1h candles for #{SYMBOL} from #{start_time}")
  end

  private

  def last_candle_time
    Candle.where(symbol: SYMBOL, timeframe: "1h").maximum(:timestamp)
  end
end