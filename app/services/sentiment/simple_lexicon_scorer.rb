# frozen_string_literal: true

module Sentiment
  class SimpleLexiconScorer
    POSITIVE_WORDS = %w[
      bullish bull breakout rally surge pump moon beat optimistic recover upside
      support
    ].freeze

    NEGATIVE_WORDS = %w[
      bearish bear dump crash rug pull downside sell-off fear panic negative
      resistance
    ].freeze

    def initialize(extra_positive: [], extra_negative: [])
      @pos = (POSITIVE_WORDS + Array(extra_positive)).map(&:downcase).to_set
      @neg = (NEGATIVE_WORDS + Array(extra_negative)).map(&:downcase).to_set
    end

    # Returns [score, confidence] in [-1.0, 1.0]
    def score(text)
      return [nil, nil] if text.to_s.strip.empty?
      tokens = tokenize(text)
      pos_count = tokens.count { |t| @pos.include?(t) }
      neg_count = tokens.count { |t| @neg.include?(t) }
      total = pos_count + neg_count
      return [0.0, 0.0] if total == 0

      raw = (pos_count - neg_count).to_f / total
      conf = [total / 6.0, 1.0].min.round(3) # saturate with ~6 hits
      [raw.round(3), conf]
    end

    private

    def tokenize(text)
      text.downcase.scan(/[a-z]+/)
    end
  end
end
