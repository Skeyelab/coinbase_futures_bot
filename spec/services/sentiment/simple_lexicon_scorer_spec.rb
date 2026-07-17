# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sentiment::SimpleLexiconScorer do
  describe ".for" do
    context "OIL-USD lexicon" do
      subject(:scorer) { described_class.for("OIL-USD") }

      it "scores a production cut as bullish for oil price" do
        score, = scorer.score("OPEC agrees production cut to support prices")
        expect(score).to be > 0
      end

      it "scores an inventory build as bearish for oil price" do
        score, = scorer.score("US crude oil inventory build larger than expected")
        expect(score).to be < 0
      end
    end

    context "unknown symbol" do
      it "falls back to the default crypto lexicon" do
        scorer = described_class.for("BTC-USD")
        score, = scorer.score("bearish crash and dump")
        expect(score).to be < 0
      end
    end
  end
end
