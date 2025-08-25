# frozen_string_literal: true

class AggregateSentimentJob < ApplicationJob
  queue_as :default

  WINDOWS = %w[5m 15m 1h].freeze

  def perform(now: Time.now.utc)
    WINDOWS.each do |win|
      aggregate_window(win, now: now)
    end
  end

  private

  def aggregate_window(window, now:)
    length = case window
             when '5m' then 5.minutes
             when '15m' then 15.minutes
             when '1h' then 1.hour
             else 15.minutes
             end

    window_end = Time.at((now.to_i / length) * length).utc
    window_start = window_end - length

    %w[BTC-USD ETH-USD].each do |sym|
      events = SentimentEvent.where(symbol: sym).where(published_at: window_start...window_end)
      count = events.count
      avg = if count > 0
              events.where.not(score: nil).average(:score)&.to_f || 0.0
            else
              0.0
            end

      # Simple z-score proxy using rolling past N windows
      past = SentimentAggregate.where(symbol: sym, window: window).where('window_end_at < ?',
                                                                         window_end).order(window_end_at: :desc).limit(50)
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
                                  weighted_score: avg.round(4),
                                  z_score: z.round(4),
                                  meta: { window_start: window_start },
                                  created_at: Time.now.utc,
                                  updated_at: Time.now.utc
                                }, unique_by: :index_sentiment_aggregates_on_sym_win_end)
    end
  end
end
