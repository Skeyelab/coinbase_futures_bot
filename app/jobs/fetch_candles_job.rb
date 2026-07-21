# frozen_string_literal: true

class FetchCandlesJob < ApplicationJob
  queue_as :default

  # 1m history is capped (issue #342): deep 1m backfill costs ~288 API
  # requests per symbol per 60 days and nothing needs it — the strategy uses
  # the last 60 1m candles and the backtest steps on 5m. Override via env.
  MAX_1M_BACKFILL_DAYS = ENV.fetch("MAX_1M_BACKFILL_DAYS", "3").to_i

  # symbols: optional product_id filter (deep backfill for specific pairs);
  # nil = all enabled contracts (hourly cron path).
  def perform(backfill_days: 7, symbols: nil)
    rest = MarketData::CoinbaseRest.new
    rest.upsert_products

    scope = Contract.enabled
    scope = scope.where(product_id: symbols) if symbols.present?

    scope.find_each do |pair|
      Rails.logger.info("[Candles] Fetching candles for #{pair.product_id}")
      fetch_1m_candles(rest, pair, backfill_days)
      fetch_5m_candles(rest, pair, backfill_days)
      fetch_15m_candles(rest, pair, backfill_days)
      fetch_30m_candles(rest, pair, backfill_days)
      fetch_1h_candles(rest, pair, backfill_days)
      fetch_1d_candles(rest, pair, backfill_days)
    end
  end

  private

  def fetch_1m_candles(rest, pair, backfill_days)
    # 1m: honor backfill_days up to MAX_1M_BACKFILL_DAYS; single request only
    # covers ~5h (300 candles), so chunk anything longer.
    backfill_days_1m = [backfill_days.to_i, MAX_1M_BACKFILL_DAYS].min
    start_time = fetch_start_time(pair.product_id, "1m", 1.minute, backfill_days_1m.days.ago)

    if Time.now.utc - start_time > 5.hours
      rest.upsert_1m_candles_chunked(
        product_id: pair.product_id,
        start_time: start_time,
        end_time: Time.now.utc,
        chunk_hours: 5
      )
    else
      rest.upsert_1m_candles(
        product_id: pair.product_id,
        start_time: start_time,
        end_time: Time.now.utc
      )
    end
  rescue => e
    Rails.logger.error("[Candles] Failed to fetch 1m candles for #{pair.product_id}: #{e.message}")
    Sentry.with_scope do |scope|
      scope.set_tag("job_type", "fetch_candles")
      scope.set_tag("timeframe", "1m")
      scope.set_tag("product_id", pair.product_id)
      scope.set_tag("error_type", "candle_fetch_error")
      scope.set_context("candle_fetch", {
        product_id: pair.product_id,
        timeframe: "1m",
        backfill_days: backfill_days,
        start_time: start_time&.iso8601
      })
      Sentry.capture_exception(e)
    end
  end

  def fetch_5m_candles(rest, pair, backfill_days)
    # 5m: honor the full backfill_days (issue #342 — the old 1-day cap made
    # deep backtest history impossible). Single request covers ~24h (288
    # candles); chunk anything longer.
    start_time = fetch_start_time(pair.product_id, "5m", 5.minutes, backfill_days.to_i.days.ago)

    if Time.now.utc - start_time > 24.hours
      rest.upsert_5m_candles_chunked(
        product_id: pair.product_id,
        start_time: start_time,
        end_time: Time.now.utc,
        chunk_hours: 24
      )
    else
      rest.upsert_5m_candles(
        product_id: pair.product_id,
        start_time: start_time,
        end_time: Time.now.utc
      )
    end
  rescue => e
    Rails.logger.error("[Candles] Failed to fetch 5m candles for #{pair.product_id}: #{e.message}")
    Sentry.with_scope do |scope|
      scope.set_tag("job_type", "fetch_candles")
      scope.set_tag("timeframe", "5m")
      scope.set_tag("product_id", pair.product_id)
      scope.set_tag("error_type", "candle_fetch_error")
      scope.set_context("candle_fetch", {
        product_id: pair.product_id,
        timeframe: "5m",
        backfill_days: backfill_days,
        start_time: start_time&.iso8601
      })
      Sentry.capture_exception(e)
    end
  end

  def fetch_15m_candles(rest, pair, backfill_days)
    # 15m: honor the full backfill_days (issue #342 — the old 3-day cap also
    # made the chunked branch below unreachable). Chunk beyond ~3 days.
    start_time = fetch_start_time(pair.product_id, "15m", 15.minutes, backfill_days.to_i.days.ago)

    if Time.now.utc - start_time > 3.days
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
    start_time = fetch_start_time(pair.product_id, "1h", 1.hour, backfill_days.to_i.days.ago)

    # Chunk at 14 days (336 candles) — the API truncates responses over ~350
    # candles, which silently capped 1h history at ~168 candles (issue #368).
    if Time.now.utc - start_time > 14.days
      rest.upsert_1h_candles_chunked(
        product_id: pair.product_id,
        start_time: start_time,
        end_time: Time.now.utc,
        chunk_days: 14
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
    # 30m has no chunked fetcher; cap at 7 days (~336 candles per request)
    start_time = fetch_start_time(pair.product_id, "30m", 30.minutes, [backfill_days.to_i, 7].min.days.ago)
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
    start_time = fetch_start_time(pair.product_id, "1d", 1.day, backfill_days.to_i.days.ago)
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

  # Where to start fetching. Normally incremental: just after the newest
  # stored candle. But when stored history is SHALLOWER than the requested
  # cutoff, refetch the whole window instead — anchoring only to the newest
  # candle can never fill backward history (the second half of issue #342;
  # upserts make the overlap refetch idempotent). Self-healing: once the
  # deep window exists, subsequent runs are incremental again.
  def fetch_start_time(product_id, timeframe, step, cutoff)
    scope = Candle.where(symbol: product_id, timeframe: timeframe)
    earliest = scope.minimum(:timestamp)
    return cutoff if earliest.nil? || earliest > cutoff + step

    [scope.maximum(:timestamp) + step, cutoff].max
  end
end
