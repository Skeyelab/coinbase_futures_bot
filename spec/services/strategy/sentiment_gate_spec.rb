# frozen_string_literal: true

require "rails_helper"

# Issue #494. The gate read `rec&.z_score&.to_f || 0.0`, so a missing
# observation became a real-looking z of 0.0, and `return false if z.abs <
# threshold` then vetoed it. Absence of evidence was treated as evidence
# against: 313 of 313 technically-complete signals were blocked across a year
# of BIP history, producing zero trades.
#
# A gate should block on evidence AGAINST, never on the absence of evidence
# FOR. That also restores CONTEXT.md's documented design, where sentiment is a
# soft input rather than an independent veto.
RSpec.describe Strategy::MultiTimeframeSignal, "sentiment gate" do
  subject(:strategy) { described_class.new(resolve_symbols: false) }

  let(:symbol) { "BTC-USD" }
  let(:now) { Time.utc(2026, 7, 27, 12, 0, 0) }

  def gate(side: :long, as_of: now)
    strategy.instance_variable_set(:@as_of, as_of)
    strategy.send(:sentiment_gate_allows?, symbol: symbol, side: side)
  end

  def aggregate!(z, at: now - 5.minutes, window: "15m")
    SentimentAggregate.create!(symbol: symbol, window: window, window_end_at: at,
      z_score: z, avg_score: 0, weighted_score: 0, count: 3)
  end

  around { |ex| ClimateControl.modify(SENTIMENT_ENABLE: "true", SENTIMENT_Z_THRESHOLD: "1.2") { ex.run } }

  context "when disabled" do
    it "allows everything" do
      ClimateControl.modify(SENTIMENT_ENABLE: "false") { expect(gate).to be true }
    end
  end

  # The defect.
  it "allows a signal when no sentiment has ever been recorded" do
    expect(gate).to be true
  end

  it "allows a signal when the reading is too weak to say anything" do
    aggregate!(0.4)

    expect(gate(side: :long)).to be true
    expect(gate(side: :short)).to be true
  end

  # Absence must not masquerade as a real z of 0.0.
  it "distinguishes a missing observation from a genuine zero" do
    expect(strategy.send(:latest_sentiment_observation, symbol, window: "15m")).to be_nil

    aggregate!(0.0)
    expect(strategy.send(:latest_sentiment_observation, symbol, window: "15m")).to be_present
  end

  context "with a fresh, strong reading" do
    it "allows a long when sentiment agrees" do
      aggregate!(2.5)
      expect(gate(side: :long)).to be true
    end

    it "blocks a long when sentiment strongly contradicts" do
      aggregate!(-2.5)
      expect(gate(side: :long)).to be false
    end

    it "blocks a short when sentiment strongly contradicts" do
      aggregate!(2.5)
      expect(gate(side: :short)).to be false
    end

    it "handles buy/sell side aliases" do
      aggregate!(-2.5)
      expect(gate(side: :buy)).to be false
      expect(gate(side: :sell)).to be true
    end
  end

  # An observation from hours ago is not evidence about now, and must not be
  # able to veto — that would reintroduce the same failure with extra steps.
  context "staleness" do
    it "ignores a reading older than the freshness window" do
      aggregate!(-3.0, at: now - 6.hours)

      expect(gate(side: :long)).to be true
    end

    it "honours a configured freshness window" do
      aggregate!(-3.0, at: now - 90.minutes)

      ClimateControl.modify(SENTIMENT_MAX_AGE_SECONDS: "7200") do
        expect(gate(side: :long)).to be false
      end
    end
  end

  # Replay must not see the future.
  it "never reads an observation after the replay cursor" do
    aggregate!(-3.0, at: now + 1.hour)

    expect(gate(side: :long, as_of: now)).to be true
  end
end
