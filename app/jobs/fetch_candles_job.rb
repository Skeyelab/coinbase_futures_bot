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

    # Fetch both 1h and 15m candles
    fetch_1h_candles(rest, btc_pair, backfill_days)
    fetch_15m_candles(rest, btc_pair, backfill_days)
  end

  private

  def fetch_1h_candles(rest, btc_pair, backfill_days)
    begin
      # Choose the later of (last known + 1h) and (backfill_days ago)
      start_time = [ last_candle_time(btc_pair.product_id, "1h")&.+(1.hour), backfill_days.to_i.days.ago ].compact.max

      # Use chunked fetching for large date ranges to avoid API limits
      if backfill_days.to_i > 30
        rest.upsert_1h_candles_chunked(
          product_id: btc_pair.product_id,
          start_time: start_time,
          end_time: Time.now.utc,
          chunk_days: 30
        )
      else
        rest.upsert_1h_candles(
          product_id: btc_pair.product_id,
          start_time: start_time,
          end_time: Time.now.utc
        )
      end
    rescue => e
      Rails.logger.error("[Candles] Failed to fetch 1h candles for #{btc_pair.product_id}: #{e.message}")
    end
  end

  def fetch_15m_candles(rest, btc_pair, backfill_days)
    begin
      # Choose the later of (last known + 15m) and (backfill_days ago)
      # Use shorter backfill for 15m candles since they're more frequent
      backfill_days_15m = [ backfill_days.to_i, 3 ].min # Cap at 3 days for 15m
      start_time = [ last_candle_time(btc_pair.product_id, "15m")&.+(15.minutes), backfill_days_15m.days.ago ].compact.max

      # Use chunked fetching for large date ranges to avoid API limits
      if backfill_days_15m > 3
        rest.upsert_15m_candles_chunked(
          product_id: btc_pair.product_id,
          start_time: start_time,
          end_time: Time.now.utc,
          chunk_days: 3
        )
      else
        rest.upsert_15m_candles(
          product_id: btc_pair.product_id,
          start_time: start_time,
          end_time: Time.now.utc
        )
      end
    rescue => e
      Rails.logger.error("[Candles] Failed to fetch 15m candles for #{btc_pair.product_id}: #{e.message}")
    end
  end

  def last_candle_time(product_id, timeframe)
    Candle.where(symbol: product_id, timeframe: timeframe).maximum(:timestamp)
  end
end
