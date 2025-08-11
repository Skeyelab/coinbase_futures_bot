# frozen_string_literal: true

class FetchCandlesJob < ApplicationJob
  queue_as :default

  def perform(backfill_days: 7)
    rest = MarketData::CoinbaseRest.new
    # Ensure products are up to date
    rest.upsert_products

    # Only process BTC-USD for now
    btc_pair = TradingPair.find_by(product_id: "BTC-USD")
    return unless btc_pair

    begin
      start_time = [ last_candle_time(btc_pair.product_id)&.+(1.hour), backfill_days.to_i.days.ago ].compact.min

      # Use chunked fetching for large date ranges to avoid API limits
      if backfill_days.to_i > 30
        rest.upsert_1h_candles_chunked(
          product_id: btc_pair.product_id,
          start_time: start_time,
          end_time: Time.now.utc,
          chunk_days: 30
        )
        Rails.logger.info("[Candles] upserted 1h candles for #{btc_pair.product_id} from #{start_time} using chunked method")
      else
        rest.upsert_1h_candles(
          product_id: btc_pair.product_id,
          start_time: start_time,
          end_time: Time.now.utc
        )
        Rails.logger.info("[Candles] upserted 1h candles for #{btc_pair.product_id} from #{start_time}")
      end
    rescue => e
      Rails.logger.error("[Candles] Failed to fetch candles for #{btc_pair.product_id}: #{e.message}")
    end
  end

  private

  def last_candle_time(product_id)
    Candle.where(symbol: product_id, timeframe: "1h").maximum(:timestamp)
  end
end
