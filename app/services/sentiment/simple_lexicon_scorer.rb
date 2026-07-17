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

    # Oil sentiment is supply/demand arithmetic, so naive word polarity is
    # backwards: a "production cut" is bullish for price, an "inventory build"
    # is bearish. Phrase entries (joined with "_") capture this; the tokenizer
    # emits matching bigrams so they can be scored.
    OIL_POSITIVE = %w[
      production_cut output_cut supply_cut inventory_draw stock_draw crude_draw
      supply_disruption outage sanctions embargo escalation conflict
      demand_growth rally surge jumps soars spikes
      gains gain rises rise climbs climb rebound rebounds rallies higher soar
      weekly_gain settles_up hostilities tensions tension unrest disruption
      blockade shortage undersupply tightens risk_premium geopolitical_risk
      supply_risk red_sea us_iran
    ].freeze

    OIL_NEGATIVE = %w[
      production_increase output_hike inventory_build stock_build crude_build
      oversupply glut surplus ceasefire de_escalation demand_destruction
      weak_demand recession plunges slides tumbles slumps
      falls fall drops drop declines decline sinks sink lower weakens
      weekly_loss settles_down truce output_increase slowdown slows
    ].freeze

    LEXICONS = {
      "OIL-USD" => {positive: OIL_POSITIVE, negative: OIL_NEGATIVE}
    }.freeze

    # Build a scorer with the lexicon appropriate for the given sentiment symbol.
    def self.for(symbol)
      lex = LEXICONS[symbol]
      return new unless lex

      new(extra_positive: lex[:positive], extra_negative: lex[:negative])
    end

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

    # Emit unigrams plus adjacent bigrams (joined with "_") so multi-word
    # lexicon phrases like "production cut" can match.
    def tokenize(text)
      words = text.downcase.scan(/[a-z]+/)
      bigrams = words.each_cons(2).map { |a, b| "#{a}_#{b}" }
      words + bigrams
    end
  end
end
