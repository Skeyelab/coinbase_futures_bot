# frozen_string_literal: true

module Ml
  # Scores a bar from a FROZEN ScorerArtifact — the fitted counterpart to the
  # hand-weighted confidence_score, sharing its "features in, one number out"
  # interface so #302 step 5 can A/B them. Everything needed to score lives
  # in the artifact row (coefficients, standardization, symbol dummies):
  # loading the same artifact anywhere yields bit-identical scores.
  class ArtifactScorer
    attr_reader :artifact

    def initialize(artifact)
      @artifact = artifact
      spec = artifact.feature_spec
      @feature_names = spec.fetch("feature_names")
      @symbols = spec.fetch("symbols")
      @baseline_symbol = spec.fetch("baseline_symbol")
      @means = spec.fetch("standardization").fetch("means")
      @stds = spec.fetch("standardization").fetch("stds")
      @intercept = artifact.coefficients.fetch("intercept").to_f
      @weights = artifact.coefficients.fetch("weights")
    end

    # P(win) in (0, 1) for one bar's features. Raises on a symbol the model
    # never saw (its dummy has no fitted coefficient — silently scoring it as
    # the baseline would be a lie) and on missing features (KeyError).
    def score(symbol:, features:)
      unless @symbols.include?(symbol)
        raise ArgumentError, "artifact #{artifact.version} was not trained on #{symbol}"
      end

      features = features.transform_keys(&:to_s)
      eta = @intercept
      @feature_names.each do |name|
        z = (features.fetch(name).to_f - @means.fetch(name).to_f) / @stds.fetch(name).to_f
        eta += @weights.fetch(name).to_f * z
      end
      eta += @weights.fetch("symbol=#{symbol}").to_f unless symbol == @baseline_symbol

      1.0 / (1.0 + Math.exp(-eta.clamp(-30.0, 30.0)))
    end

    # The probability on the rules scorer's 0-100 confidence scale, for
    # side-by-side comparison and threshold reuse.
    def score100(symbol:, features:)
      (score(symbol: symbol, features: features) * 100.0).round(1)
    end

    # Convenience for spot-checks and backtest wiring: extract this bar's
    # features from stored candles (with the artifact's own extractor config)
    # and score them. Returns nil when the bar lacks sufficient history.
    def score_at(symbol:, timestamp:)
      features = FeatureExtractor.new(symbol: symbol,
        config: artifact.feature_spec.fetch("extractor_config", {}).symbolize_keys)
        .features_for_range(from: timestamp, to: timestamp)[timestamp.to_time.utc]
      return nil unless features

      score(symbol: symbol, features: features)
    end
  end
end
