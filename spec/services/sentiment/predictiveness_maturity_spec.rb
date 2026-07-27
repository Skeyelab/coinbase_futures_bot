# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sentiment::PredictivenessMaturity do
  describe ".label" do
    # The defect (#468): thresholds counted rows, so `high` was reachable in
    # under a week. On 2026-07-27, with six days of history, every symbol read
    # `high` — including oil at a 0.25 hit rate, which invites inverting a
    # signal that six days of overlapping windows cannot support.
    it "refuses high on a short calendar span no matter how many observations" do
      expect(described_class.label(effective_n: 5_000, signal_count: 900, span_days: 6))
        .not_to eq("high")
    end

    it "is low when there is barely any independent evidence" do
      expect(described_class.label(effective_n: 6, signal_count: 2, span_days: 6)).to eq("low")
    end

    it "is moderate with enough independent observations but too little span" do
      expect(described_class.label(effective_n: 36, signal_count: 25, span_days: 6)).to eq("moderate")
    end

    it "reaches high once span and independent evidence both suffice" do
      expect(described_class.label(effective_n: 180, signal_count: 40, span_days: 45)).to eq("high")
    end

    it "stays moderate when signal-strength observations are too few to trust a hit rate" do
      expect(described_class.label(effective_n: 180, signal_count: 5, span_days: 45)).to eq("moderate")
    end
  end
end
