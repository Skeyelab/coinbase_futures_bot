# frozen_string_literal: true

module Sentiment
  # Forward measurement harness (follow-up to #431–#434). Answers: does a symbol's
  # sentiment z-score at time t predict the price return over t -> t+horizon?
  #
  # Joins each SentimentAggregate (z-score, window_end_at) to the price now and
  # `horizon_hours` later, then reports:
  #   - correlation : Pearson r between z-score and forward return
  #   - hit_rate    : of the "signal" aggregates (|z| >= z_threshold), the fraction
  #                   whose z sign matched the realized return direction
  #   - n / signal_count
  #
  # The raw inputs (SentimentAggregate + Candle) accumulate continuously, so this
  # is runnable anytime — it just needs weeks of data to mean something. Bias
  # warning: sentiment and price are recorded live going forward, so this measures
  # genuine forward predictiveness, not hindsight-fit.
  class PredictivenessStudy
    def initialize(sentiment_symbol:, price_symbol:, window: "1h", horizon_hours: 4, z_threshold: 1.0)
      @sentiment_symbol = sentiment_symbol
      @price_symbol = price_symbol
      @window = window
      @horizon_hours = horizon_hours.to_i
      @z_threshold = z_threshold.to_f
    end

    def run(from:, to:)
      samples = build_samples(from, to)
      zs = samples.map { |s| s[:z] }
      rets = samples.map { |s| s[:forward_return] }
      signals = samples.select { |s| s[:z].abs >= @z_threshold }

      {
        sentiment_symbol: @sentiment_symbol,
        price_symbol: @price_symbol,
        horizon_hours: @horizon_hours,
        z_threshold: @z_threshold,
        n: samples.size,
        correlation: pearson(zs, rets),
        signal_count: signals.size,
        hit_rate: hit_rate(signals),
        mean_forward_return: (rets.empty? ? nil : rets.sum / rets.size)
      }
    end

    private

    def build_samples(from, to)
      aggregates = SentimentAggregate
        .where(symbol: @sentiment_symbol, window: @window, window_end_at: from..to)
        .order(:window_end_at)

      aggregates.filter_map do |a|
        now = price_at(a.window_end_at)
        later = price_at(a.window_end_at + @horizon_hours.hours)
        next if now.nil? || later.nil? || now.to_f <= 0

        {z: a.z_score.to_f, forward_return: (later.to_f - now.to_f) / now.to_f}
      end
    end

    # Most recent price at or before `time` (last known close).
    def price_at(time)
      Candle.where(symbol: @price_symbol, timeframe: "1h")
        .where("timestamp <= ?", time).order(timestamp: :desc).limit(1).pick(:close)
    end

    def hit_rate(signals)
      return nil if signals.empty?

      hits = signals.count { |s| (s[:z] <=> 0) == (s[:forward_return] <=> 0) }
      hits.to_f / signals.size
    end

    def pearson(xs, ys)
      n = xs.size
      return nil if n < 2

      mx = xs.sum / n
      my = ys.sum / n
      cov = xs.zip(ys).sum { |x, y| (x - mx) * (y - my) }
      vx = xs.sum { |x| (x - mx)**2 }
      vy = ys.sum { |y| (y - my)**2 }
      return nil if vx.zero? || vy.zero?

      cov / Math.sqrt(vx * vy)
    end
  end
end
