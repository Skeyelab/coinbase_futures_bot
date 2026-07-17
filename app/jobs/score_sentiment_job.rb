# frozen_string_literal: true

class ScoreSentimentJob < ApplicationJob
  queue_as :default

  BATCH_SIZE = 200

  def perform
    scorers = Hash.new { |h, symbol| h[symbol] = Sentiment::SimpleLexiconScorer.for(symbol) }
    SentimentEvent.unscored.order(published_at: :asc).limit(BATCH_SIZE).find_each do |evt|
      score, conf = scorers[evt.symbol].score(text_for(evt))
      if score
        evt.update_columns(score: score, confidence: conf, updated_at: Time.now.utc)
      else
        evt.update_columns(score: 0.0, confidence: 0.0, updated_at: Time.now.utc)
      end
    rescue => e
      Rails.logger.error("ScoreSentimentJob failed for event #{evt.id}: #{e.class} #{e.message}")
    end
  end

  private

  # RSS clients store the article body under "description"; CryptoPanic uses
  # "summary". Score whichever is present alongside the title so the body text
  # contributes tokens, not just the headline.
  def text_for(evt)
    summary = evt.meta.dig("summary") || evt.meta.dig("description")
    [evt.title, summary].compact.join(". ")
  end
end
