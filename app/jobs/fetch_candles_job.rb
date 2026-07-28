# frozen_string_literal: true

class FetchCandlesJob < ApplicationJob
  queue_as :default

  # 1m history is capped by default (issue #342): deep 1m costs ~288 API
  # requests per symbol per 60 days and the hourly cron doesn't need it.
  # Pass max_1m_days (or set MAX_1M_BACKFILL_DAYS) for deliberate deep
  # backfills — long-range walk-forward validation needs 1m depth because
  # the strategy requires 60x1m before every evaluation (issue #378).
  #
  # This 3-day window is a DELIBERATE steady-state choice, not a depth target.
  # It is the right cost for keeping an already-deep symbol current; it is the
  # wrong thing to be a symbol's entire history. The path that gives a symbol
  # real depth is the one-time deep backfill below — the two work together and
  # neither is sufficient alone (issue #506).
  DEFAULT_MAX_1M_BACKFILL_DAYS = 3

  # One-time deep 1m backfill for contracts that have never had one.
  #
  # Issue #506: adding a contract starts collection, but the rolling window
  # meant "ingesting" never produced usable 1m history. On 2026-07-27 a routine
  # monthly roll left five contracts with 1–72 1m candles each, all of them
  # looking fine on 5m/15m/1h. Three could not emit a signal at all, and nothing
  # surfaced it — which is worse than a loud failure, because a rolled contract
  # is not something anyone "adds" and then checks.
  #
  # Driven off a per-contract stamp rather than hooked into product ingestion,
  # so it is self-healing instead of forward-only: contracts already starved
  # when this ships get their history on the next cron tick with no manual step.
  DEEP_1M_BACKFILL_DAYS = 120

  # Deep backfill is ~288 requests per symbol per 60 days, so draining several
  # starved contracts at once would turn an hourly maintenance job into a
  # sustained burst against the venue. One per run drains a monthly roll's worth
  # in a few hours, which is far inside the window that matters (the symbol is
  # suspended and cannot trade until it earns enablement anyway).
  DEEP_1M_BACKFILL_PER_RUN = 1

  # symbols: optional product_id filter (deep backfill for specific pairs);
  # nil = all enabled contracts (hourly cron path).
  def perform(backfill_days: 7, symbols: nil, max_1m_days: nil)
    @explicit_1m_days = !max_1m_days.nil? || ENV["MAX_1M_BACKFILL_DAYS"].present?
    @max_1m_days = (max_1m_days || ENV.fetch("MAX_1M_BACKFILL_DAYS", DEFAULT_MAX_1M_BACKFILL_DAYS)).to_i
    rest = MarketData::CoinbaseRest.new
    rest.upsert_products

    # Expired contracts must not stay enabled (issue #368): subscriptions,
    # backfill, and signal evaluation would keep targeting dead symbols.
    Contract.enabled.where(expiration_date: ...Date.current).find_each do |expired|
      expired.update!(enabled: false)
      Rails.logger.warn("[Candles] Disabled expired contract #{expired.product_id} (expired #{expired.expiration_date})")
    end

    scope = Contract.enabled
    scope = scope.where(product_id: symbols) if symbols.present?

    @deep_1m_pending = deep_1m_candidates(scope)
    if @deep_1m_pending.any?
      awaiting = scope.where(deep_1m_backfilled_at: nil).count
      Rails.logger.info(
        "[Candles] Deep 1m backfill (#{DEEP_1M_BACKFILL_DAYS}d) this run: " \
        "#{@deep_1m_pending.to_a.join(", ")} (#{awaiting} contract(s) awaiting one)"
      )
    end

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

  # Which contracts get a WIDENED 1m window on this run (issue #506).
  #
  # Deliberately widens the existing 1m fetch rather than adding a second pass.
  # A separate pass double-fetched: an operator asking for `max_1m_days: 60`
  # got their 60-day walk AND a 120-day one behind it, for the same minutes.
  # One fetch per contract per run, sometimes deeper, is the honest shape.
  def deep_1m_candidates(scope)
    # An explicit depth means the caller owns the decision; do not second-guess
    # it by silently fetching a different window than the one they asked for.
    return Set.new if @explicit_1m_days

    pending = scope.where(deep_1m_backfilled_at: nil).to_a
    return Set.new if pending.empty?

    needs_fetch = pending.reject { |c| record_existing_depth(c) }
    return Set.new if needs_fetch.empty?

    # NEEDIEST FIRST, not oldest row first. Ordering by id served the starved
    # contracts LAST, because a contract that rolled in yesterday is the newest
    # row — the exact contracts this exists for would have waited ~20 hours
    # behind healthy ones at one per run. Observed on exo-mini: 20 pending,
    # with the three that could not emit a signal at the back of the queue.
    counts = Candle.where(symbol: needs_fetch.map(&:product_id), timeframe: "1m")
      .group(:symbol).count
    needs_fetch
      .sort_by { |c| [counts.fetch(c.product_id, 0), c.product_id] }
      .first(DEEP_1M_BACKFILL_PER_RUN)
      .map(&:product_id)
      .to_set
  end

  # A contract whose 1m history already reaches past the deep window has had its
  # backfill, just before the stamp existed — record that rather than re-walking
  # it. Without this the first ~14 runs on exo-mini would have spent themselves
  # refetching minutes BIP (466k 1m candles) and BTC-USD (533k) already hold,
  # while three unusable contracts waited behind them.
  def record_existing_depth(contract)
    earliest = Candle.where(symbol: contract.product_id, timeframe: "1m").minimum(:timestamp)
    return false if earliest.nil?
    # A day of slack: the venue's own history may not reach the full window.
    return false if earliest > (DEEP_1M_BACKFILL_DAYS - 1).days.ago

    contract.update!(deep_1m_backfilled_at: Time.now.utc)
    Rails.logger.info(
      "[Candles] #{contract.product_id} already has 1m back to #{earliest.to_date} " \
      "— recording deep backfill without refetching"
    )
    true
  end

  # True when this run's 1m fetch for `pair` is deep enough to count as the
  # contract's one-time backfill — either because we chose it, or because the
  # caller asked for at least as much depth as we would have.
  def deep_1m_run_for?(pair)
    return true if @deep_1m_pending.include?(pair.product_id)

    @explicit_1m_days && @max_1m_days >= DEEP_1M_BACKFILL_DAYS &&
      pair.deep_1m_backfilled_at.nil?
  end

  def fetch_1m_candles(rest, pair, backfill_days)
    # 1m: honor backfill_days up to MAX_1M_BACKFILL_DAYS; single request only
    # covers ~5h (300 candles), so chunk anything longer.
    #
    # A contract that has never had a deep backfill gets the deep window INSTEAD
    # of the rolling one on this run — the rolling window is a maintenance
    # figure, and applying it to a contract with no history is what left five
    # contracts unusable through a monthly roll (issue #506).
    deep = deep_1m_run_for?(pair)
    backfill_days_1m = if deep
      DEEP_1M_BACKFILL_DAYS
    else
      [backfill_days.to_i, @max_1m_days].min
    end
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

    # Stamped only after the fetch returns. A failed deep backfill must stay
    # pending — the whole point is that a starved contract does not quietly
    # remain starved, and stamping up front would recreate exactly that.
    if deep
      pair.update!(deep_1m_backfilled_at: Time.now.utc)
      Rails.logger.info(
        "[Candles] Deep 1m backfill complete for #{pair.product_id} " \
        "(#{Candle.where(symbol: pair.product_id, timeframe: "1m").count} 1m candles)"
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
