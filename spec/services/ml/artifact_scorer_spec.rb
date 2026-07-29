# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ml::ArtifactScorer do
  let(:artifact) do
    ScorerArtifact.create!(
      version: "logistic-long-test",
      direction: "long",
      timeframe: "5m",
      tp_frac: 0.020,
      sl_frac: 0.012,
      horizon: 288,
      feature_spec: {
        "feature_names" => %w[trend_1h align_5m],
        "symbols" => %w[BIP-20DEC30-CDE ETP-20DEC30-CDE],
        "baseline_symbol" => "BIP-20DEC30-CDE",
        "standardization" => {
          "means" => {"trend_1h" => 0.01, "align_5m" => 0.0},
          "stds" => {"trend_1h" => 0.02, "align_5m" => 0.005}
        }
      },
      coefficients: {
        "intercept" => -1.0,
        "weights" => {"trend_1h" => 0.8, "align_5m" => -0.4, "symbol=ETP-20DEC30-CDE" => 0.25}
      }
    ).tap(&:freeze_artifact!)
  end

  let(:scorer) { described_class.new(artifact) }

  describe "#score" do
    it "standardizes features with the artifact's constants and applies the logistic (hand-checkable)" do
      # z_trend = (0.03 - 0.01) / 0.02 = 1.0; z_align = (0.005 - 0) / 0.005 = 1.0
      # eta = -1.0 + 0.8*1.0 - 0.4*1.0 = -0.6 (baseline symbol: no dummy term)
      p = scorer.score(symbol: "BIP-20DEC30-CDE",
        features: {"trend_1h" => 0.03, "align_5m" => 0.005})

      expect(p).to be_within(1e-12).of(1.0 / (1.0 + Math.exp(0.6)))
    end

    it "adds the symbol dummy coefficient for a non-baseline symbol" do
      base = scorer.score(symbol: "BIP-20DEC30-CDE",
        features: {"trend_1h" => 0.01, "align_5m" => 0.0})
      # eta_base = -1.0 (z's are 0); eta_etp = -1.0 + 0.25
      etp = scorer.score(symbol: "ETP-20DEC30-CDE",
        features: {"trend_1h" => 0.01, "align_5m" => 0.0})

      expect(base).to be_within(1e-12).of(1.0 / (1.0 + Math.exp(1.0)))
      expect(etp).to be_within(1e-12).of(1.0 / (1.0 + Math.exp(0.75)))
    end

    it "refuses to score a symbol the artifact was not trained on" do
      expect {
        scorer.score(symbol: "SLP-20DEC30-CDE", features: {"trend_1h" => 0.0, "align_5m" => 0.0})
      }.to raise_error(ArgumentError, /not trained/)
    end

    it "refuses to score when a declared feature is missing" do
      expect {
        scorer.score(symbol: "BIP-20DEC30-CDE", features: {"trend_1h" => 0.0})
      }.to raise_error(KeyError)
    end

    it "is deterministic across a DB round-trip of the artifact" do
      features = {"trend_1h" => 0.021, "align_5m" => -0.003}
      first = scorer.score(symbol: "ETP-20DEC30-CDE", features: features)

      fresh = described_class.new(ScorerArtifact.find(artifact.id))
      expect(fresh.score(symbol: "ETP-20DEC30-CDE", features: features)).to eq(first)
    end
  end

  describe "#score100" do
    it "scales the probability to the 0-100 confidence range for A/B against the rules scorer" do
      features = {"trend_1h" => 0.03, "align_5m" => 0.005}
      p = scorer.score(symbol: "BIP-20DEC30-CDE", features: features)

      expect(scorer.score100(symbol: "BIP-20DEC30-CDE", features: features))
        .to eq((p * 100.0).round(1))
    end
  end
end
