# frozen_string_literal: true

class AggregateSentimentJob < ApplicationJob
  queue_as :default

  WINDOWS = %w[5m 15m 1h].freeze
  DEFAULT_SYMBOLS = %w[BTC-USD ETH-USD].freeze

  def perform(now: Time.now.utc)
    symbols = resolve_symbols
    WINDOWS.each do |win|
      aggregate_window(win, symbols: symbols, now: now)
    end
  end

  private

  # Symbols enabled for trading drive which sentiment aggregates we build,
  # so adding a contract (crypto or commodity) needs no code change here.
  # Falls back to the crypto defaults when no contracts are enabled.
  def resolve_symbols
    enabled = Sentiment::ContractSymbolMapper.sentiment_symbols_for_enabled_contracts
    enabled.presence || DEFAULT_SYMBOLS
  end

  # Confidence- and source-trust-weighted mean of scores in the window:
  # Σ(weightᵢ·confᵢ·scoreᵢ) / Σ(weightᵢ·confᵢ). Falls back to the plain avg when
  # there is no weight to distribute (all confidences zero, or no scored events).
  def weighted_score(scored_events, config:, fallback:)
    num = 0.0
    den = 0.0
    scored_events.each do |evt|
      w = config.weight_for(evt.source) * (evt.confidence || 0.0)
      num += w * evt.score
      den += w
    end
    (den > 0) ? num / den : fallback
  end

  def aggregate_window(window, symbols:, now:)
    length = case window
    when "5m" then 5.minutes
    when "15m" then 15.minutes
    when "1h" then 1.hour
    else 15.minutes
    end

    window_end = Time.at((now.to_i / length) * length).utc
    window_start = window_end - length

    config = Sentiment::SourceConfig.default

    symbols.each do |sym|
      events = SentimentEvent.where(symbol: sym).where(published_at: window_start...window_end)
      count = events.count
      scored = events.where.not(score: nil)
      avg = (count > 0) ? (scored.average(:score)&.to_f || 0.0) : 0.0
      weighted = weighted_score(scored, config: config, fallback: avg)

      # Simple z-score proxy using rolling past N windows. Empty windows are
      # excluded: for low-volume symbols (e.g. OIL) most windows have no events,
      # and letting their zero avg_score into the baseline collapses the stddev
      # so a single scored article produces an explosive, meaningless z-spike.
      past = SentimentAggregate.where(symbol: sym, window: window).where("window_end_at < ?",
        window_end).where("count > 0").order(window_end_at: :desc).limit(50)
      mu = past.average(:avg_score)&.to_f || 0.0
      sigma = Math.sqrt(past.average("POWER(avg_score - #{mu}, 2)")&.to_f || 0.0)
      z = if sigma > 0
        (avg - mu) / sigma
      else
        0.0
      end

      SentimentAggregate.upsert({
        symbol: sym,
        window: window,
        window_end_at: window_end,
        count: count,
        avg_score: avg.round(4),
        weighted_score: weighted.round(4),
        z_score: z.round(4),
        meta: {window_start: window_start},
        created_at: Time.now.utc,
        updated_at: Time.now.utc
      }, unique_by: :index_sentiment_aggregates_on_sym_win_end)
    end
  end
end
