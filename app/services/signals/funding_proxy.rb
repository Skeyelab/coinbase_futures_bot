# frozen_string_literal: true

module Signals
  # Funding-rate proxy from owned data (issue #569). The CDE Derivatives API
  # is member-only, so funding HISTORY cannot be backfilled at this account
  # tier — but Coinbase funding is premium-based, and 370d of 1m candles
  # exist for both legs. The hourly premium
  #
  #   (perp hourly close - spot hourly close) / spot hourly close
  #
  # tracks the real funding snapshots at r = 0.77 over their 143 overlapping
  # hours, which is enough fidelity for a crowding-skew SIGNAL (sign +
  # relative magnitude). Settlement accounting stays on the real snapshot
  # pipeline (#391); this class is for history and signals only.
  #
  # Honesty rules, all as_of-bounded (backtest discipline, no look-ahead):
  #   - an hour bucket H is COMPLETE only once the clock has passed its last
  #     1m bar (H + 1h <= as_of + 1m, matching the repo convention that a
  #     candle stamped T is readable at T). Completeness is clock-based, not
  #     data-based, so gappy history closes its buckets on time.
  #   - the bucket close is the last stored 1m close <= as_of in the bucket
  #   - hours missing either leg are skipped, never interpolated
  #
  # The z-score is regime-relative: the latest premium judged against the
  # mean/sample-stddev of the PRIOR `window` premiums, so "skew" means
  # "extreme for the current regime", not an absolute threshold.
  #
  # Bucket closes are cached across calls (monotone as_of, the backtest
  # access pattern): after the first full read, each call fetches only the
  # minutes since the previous as_of. A rewound as_of drops the cache and
  # re-reads — correctness first, speed second.
  class FundingProxy
    HOUR = 3600

    attr_writer :candle_source

    def initialize(perp_symbol:, spot_symbol:, window: 168, candle_source: nil)
      @perp_symbol = perp_symbol
      @spot_symbol = spot_symbol
      @window = window.to_i
      @candle_source = candle_source
      @buckets = {}       # symbol => {hour Time => [last candle ts, close]}
      @fetched_until = {} # symbol => last as_of served
      @cold_hours = {}    # symbol => hours the cold fetch was sized for
    end

    def candle_source
      @candle_source ||= CandleSource::Database.new
    end

    # Chronological [{hour:, premium:, perp_close:, spot_close:}] for the last
    # `hours` COMPLETE hour buckets at or before as_of.
    def premium_series(as_of:, hours:)
      perp = closes_by_hour(@perp_symbol, as_of, hours)
      spot = closes_by_hour(@spot_symbol, as_of, hours)

      joint = (perp.keys & spot.keys).sort.last(hours)
      joint.map do |hour|
        perp_close = perp[hour]
        spot_close = spot[hour]
        {hour: hour, premium: (perp_close - spot_close) / spot_close,
         perp_close: perp_close, spot_close: spot_close}
      end
    end

    # Latest premium vs the trailing window: {z:, premium:, mean:, stddev:,
    # perp_close:, hour:}. Nil when fewer than window + 1 joint hours exist
    # or the trailing window has no variance (z undefined) — callers treat
    # both as "not enough evidence to call a skew".
    def z_score(as_of:)
      series = premium_series(as_of: as_of, hours: @window + 1)
      return nil if series.size < @window + 1

      current = series.last
      trailing = series.first(@window).map { |row| row[:premium] }
      mean = trailing.sum / @window
      sd = Indicators.stddev(trailing, @window)
      return nil if sd.nil? || sd.zero?

      {z: (current[:premium] - mean) / sd, premium: current[:premium],
       mean: mean, stddev: sd, perp_close: current[:perp_close], hour: current[:hour]}
    end

    # Cross-validation against the real FundingRate snapshots (#391): Pearson
    # r between the proxy premium of the hour ENDING at each funding_time and
    # the stored rate. Used by the operator sanity task to assert the r ~ 0.77
    # relationship holds as snapshots accrue. {n:, r:} — r nil below 2 pairs
    # or under zero variance.
    def correlation_with_funding(from:, to:)
      rates = FundingRate.for_product(@perp_symbol)
        .where(funding_time: from..to).chronological
      return {n: 0, r: nil} if rates.empty?

      hours = ((to - from) / HOUR).ceil + 2
      premiums = premium_series(as_of: to, hours: hours)
        .to_h { |row| [row[:hour], row[:premium]] }

      pairs = rates.filter_map do |rate|
        hour = hour_ending_at(rate.funding_time)
        premiums.key?(hour) ? [premiums[hour], rate.funding_rate.to_f] : nil
      end
      {n: pairs.size, r: pearson(pairs)}
    end

    private

    # The hour bucket whose close the venue's premium sampling for a funding
    # timestamp last saw: the bucket ENDING at (or last ending before) it.
    def hour_ending_at(funding_time)
      bucket_of(funding_time - 1)
    end

    def bucket_of(time)
      Time.zone.at((time.to_i / HOUR) * HOUR)
    end

    # {hour => close} for complete buckets <= as_of, served from the
    # incremental cache. `hours` only sizes the cold-start fetch.
    def closes_by_hour(symbol, as_of, hours)
      refresh(symbol, as_of, hours)
      cutoff = as_of + 60 # bucket H complete iff H + 1h <= as_of + 1m
      @buckets[symbol].each_with_object({}) do |(hour, (_ts, close)), out|
        out[hour] = close if hour + HOUR <= cutoff
      end
    end

    def refresh(symbol, as_of, hours)
      last = @fetched_until[symbol]
      # Rewound as_of, or a deeper history ask than the cold fetch covered:
      # drop the cache and re-read rather than serve a series with a silently
      # missing head.
      if last && (as_of < last || hours > @cold_hours[symbol].to_i)
        @buckets[symbol] = {}
        last = nil
      end
      cache = (@buckets[symbol] ||= {})
      @cold_hours[symbol] = [hours, @cold_hours[symbol].to_i].max if last.nil?

      # Cold: enough minutes to fill `hours` buckets plus the in-progress
      # hour. Warm: only the minutes elapsed since the last fetch.
      limit = if last
        ((as_of - last) / 60.0).ceil + 61
      else
        hours * 60 + 60
      end

      candle_source.recent(symbol: symbol, timeframe: :one_minute,
        limit: limit, as_of: as_of).each do |candle|
        hour = bucket_of(candle.timestamp)
        ts, _close = cache[hour]
        cache[hour] = [candle.timestamp, candle.close.to_f] if ts.nil? || candle.timestamp >= ts
      end
      @fetched_until[symbol] = as_of
    end

    def pearson(pairs)
      n = pairs.size
      return nil if n < 2

      xs = pairs.map(&:first)
      ys = pairs.map(&:last)
      mx = xs.sum / n.to_f
      my = ys.sum / n.to_f
      cov = pairs.sum { |x, y| (x - mx) * (y - my) }
      vx = xs.sum { |x| (x - mx)**2 }
      vy = ys.sum { |y| (y - my)**2 }
      return nil if vx.zero? || vy.zero?

      cov / Math.sqrt(vx * vy)
    end
  end
end
