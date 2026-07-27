# frozen_string_literal: true

require "rails_helper"

RSpec.describe SignalDecision do
  def decide!(reason, product_id: "BTC-USD", disposition: described_class::REJECTED, at: Time.current)
    described_class.create!(product_id: product_id, disposition: disposition,
      reason: reason, evaluated_at: at)
  end

  describe ".rejection_histogram" do
    # The query this table exists for: which gate is actually stopping trades.
    it "ranks reasons by frequency, most common first" do
      3.times { decide!("low_confidence") }
      5.times { decide!("strategy_no_signal") }
      decide!("protection_active")

      expect(described_class.rejection_histogram.to_a)
        .to eq([["strategy_no_signal", 5], ["low_confidence", 3], ["protection_active", 1]])
    end

    it "excludes traded rows — the histogram is about refusals" do
      decide!("traded", disposition: described_class::TRADED)
      decide!("low_confidence")

      expect(described_class.rejection_histogram).to eq({"low_confidence" => 1})
    end

    it "scopes to a product and a window" do
      decide!("low_confidence", product_id: "ETH-USD")
      decide!("low_confidence", at: 3.days.ago)
      decide!("protection_active")

      expect(described_class.rejection_histogram(product_id: "BTC-USD", since: 24.hours.ago))
        .to eq({"protection_active" => 1})
    end
  end

  describe ".conversion_rate" do
    # Makes observed trade frequency comparable against a backtest's — the
    # check that would reveal the deployed system is not the backtested one.
    it "is the share of evaluations that reached an order" do
      3.times { decide!("low_confidence") }
      decide!("traded", disposition: described_class::TRADED)

      expect(described_class.conversion_rate).to eq(0.25)
    end

    it "is nil rather than zero when nothing was evaluated" do
      expect(described_class.conversion_rate).to be_nil
    end
  end

  it "requires a known disposition" do
    expect(described_class.new(product_id: "BTC-USD", disposition: "maybe",
      reason: "x", evaluated_at: Time.current)).not_to be_valid
  end
end
