# frozen_string_literal: true

class FetchCandlesJob < ApplicationJob
  queue_as :default

  def perform(backfill_days: 7)
    rest = MarketData::CoinbaseRest.new
    rest.upsert_products

    TradingPair.enabled.find_each do |pair|
      Rails.logger.info("[Candles] Fetching candles for #{pair.product_id}")
      fetch_15m_candles(rest, pair, backfill_days)
      fetch_30m_candles(rest, pair, backfill_days)
      fetch_1h_candles(rest, pair, backfill_days)
      fetch_1d_candles(rest, pair, backfill_days)
    end
  end

  private

  def fetch_15m_candles(rest, pair, backfill_days)
    # Choose the later of (last known + 15m) and (backfill_days ago)
    # Use shorter backfill for 15m candles since they're more frequent
    backfill_days_15m = [backfill_days.to_i, 3].min # Cap at 3 days for 15m
    start_time = [last_candle_time(pair.product_id, "15m")&.+(15.minutes), backfill_days_15m.days.ago].compact.max

    # Use chunked fetching for large date ranges to avoid API limits
    if backfill_days_15m > 3
      rest.upsert_15m_candles_chunked(
        product_id: pair.product_id,
        start_time: start_time,
        end_time: Time.now.utc,
        chunk_days: 3
      )
    else
      rest.upsert_15m_candles(
        product_id: pair.product_id,
        start_time: start_time,
        end_time: Time.now.utc
      )
    end
  rescue => e
    Rails.logger.error("[Candles] Failed to fetch 15m candles for #{pair.product_id}: #{e.message}")

    # Track candle fetching errors with specific context
    Sentry.with_scope do |scope|
      scope.set_tag("job_type", "fetch_candles")
      scope.set_tag("timeframe", "15m")
      scope.set_tag("product_id", pair.product_id)
      scope.set_tag("error_type", "candle_fetch_error")

      scope.set_context("candle_fetch", {
        product_id: pair.product_id,
        timeframe: "15m",
        backfill_days: backfill_days,
        start_time: start_time&.iso8601
      })

      Sentry.capture_exception(e)
    end
  end

  def fetch_1h_candles(rest, pair, backfill_days)
    # Choose the later of (last known + 1h) and (backfill_days ago)
    start_time = [last_candle_time(pair.product_id, "1h")&.+(1.hour), backfill_days.to_i.days.ago].compact.max

    # Use chunked fetching for large date ranges to avoid API limits
    if backfill_days.to_i > 30
      rest.upsert_1h_candles_chunked(
        product_id: pair.product_id,
        start_time: start_time,
        end_time: Time.now.utc,
        chunk_days: 30
      )
    else
      rest.upsert_1h_candles(
        product_id: pair.product_id,
        start_time: start_time,
        end_time: Time.now.utc
      )
    end
  rescue => e
    Rails.logger.error("[Candles] Failed to fetch 1h candles for #{pair.product_id}: #{e.message}")

    # Track candle fetching errors with specific context
    Sentry.with_scope do |scope|
      scope.set_tag("job_type", "fetch_candles")
      scope.set_tag("timeframe", "1h")
      scope.set_tag("product_id", pair.product_id)
      scope.set_tag("error_type", "candle_fetch_error")

      scope.set_context("candle_fetch", {
        product_id: pair.product_id,
        timeframe: "1h",
        backfill_days: backfill_days,
        start_time: start_time&.iso8601
      })

      Sentry.capture_exception(e)
    end
  end

  def fetch_30m_candles(rest, pair, backfill_days)
    start_time = [last_candle_time(pair.product_id, "30m")&.+(30.minutes), backfill_days.to_i.days.ago].compact.max
    rest.upsert_30m_candles(product_id: pair.product_id, start_time: start_time, end_time: Time.now.utc)
  rescue => e
    Rails.logger.error("[Candles] Failed to fetch 30m candles for #{pair.product_id}: #{e.message}")
    Sentry.with_scope do |scope|
      scope.set_tag("job_type", "fetch_candles")
      scope.set_tag("timeframe", "30m")
      scope.set_tag("product_id", pair.product_id)
      scope.set_context("candle_fetch", {product_id: pair.product_id, timeframe: "30m", start_time: start_time&.iso8601})
      Sentry.capture_exception(e)
    end
  end

  def fetch_1d_candles(rest, pair, backfill_days)
    start_time = [last_candle_time(pair.product_id, "1d")&.+(1.day), backfill_days.to_i.days.ago].compact.max
    rest.upsert_1d_candles(product_id: pair.product_id, start_time: start_time, end_time: Time.now.utc)
  rescue => e
    Rails.logger.error("[Candles] Failed to fetch 1d candles for #{pair.product_id}: #{e.message}")
    Sentry.with_scope do |scope|
      scope.set_tag("job_type", "fetch_candles")
      scope.set_tag("timeframe", "1d")
      scope.set_tag("product_id", pair.product_id)
      scope.set_context("candle_fetch", {product_id: pair.product_id, timeframe: "1d", start_time: start_time&.iso8601})
      Sentry.capture_exception(e)
    end
  end

  def last_candle_time(product_id, timeframe)
    Candle.where(symbol: product_id, timeframe: timeframe).maximum(:timestamp)
  end
end
