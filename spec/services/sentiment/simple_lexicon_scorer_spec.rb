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

      # Real headlines that previously scored 0.0 (neutral) despite being clearly
      # bullish for crude — geopolitical supply risk and price-up language.
      it "scores geopolitical supply-risk headlines as bullish" do
        score, = scorer.score("Oil settles up on renewed US-Iran hostilities and threat of Red Sea closure")
        expect(score).to be > 0
      end

      it "scores a weekly-gain / risk-premium headline as bullish" do
        score, = scorer.score("Geopolitical Risk Premium Returns as Crude Posts Biggest Weekly Gain in Months")
        expect(score).to be > 0
      end

      it "scores plain price-up language as bullish" do
        score, = scorer.score("Oil rises and climbs to weekly gain")
        expect(score).to be > 0
      end

      it "scores plain price-down language as bearish" do
        score, = scorer.score("Oil falls and drops on ceasefire hopes")
        expect(score).to be < 0
      end

      it "stays neutral on a non-directional oil headline" do
        score, = scorer.score("BP and ConocoPhillips partner in Iraq oilfield")
        expect(score).to eq(0.0)
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
