# frozen_string_literal: true

require "rails_helper"

# Backtest::Engine hardcoded its funding fallback at 2.0 bps/interval. Measured
# against BIP's own snapshots that is 21x reality (0.0938 bps/hr over 134 rows).
# Funding history is NOT reconstructible, so on a 370-day window ~364 days are
# priced by this constant — and because funding is charged per unit of TIME
# HELD, a 21x error penalises long-hold shapes hardest, which is exactly the
# dimension a target-shape sweep compares (#485, #497).
RSpec.describe Funding::Schedule, ".observed_fallback_rate" do
  def observe(product_id, rate, at)
    FundingRate.create!(
      product_id: product_id, funding_rate: rate, funding_time: at,
      observed_at: at - 1.minute, funding_interval_seconds: 3600
    )
  end

  it "is nil for a product with no observations, so nothing is charged phantom funding" do
    expect(described_class.observed_fallback_rate(product_id: "NOL-19AUG26-CDE")).to be_nil
  end

  it "derives the rate from what the product actually does" do
    base = 6.hours.ago.change(min: 0)
    [0.00001, 0.00002, 0.00003].each_with_index { |r, i| observe("BIP-20DEC30-CDE", r, base + i.hours) }

    expect(described_class.observed_fallback_rate(product_id: "BIP-20DEC30-CDE"))
      .to be_within(1e-9).of(0.00002)
  end

  # The constant is documented as an ADVERSE knob, and this codebase refuses to
  # bank expected funding income into a decision. A negative-funding regime must
  # not turn the fallback into a subsidy.
  it "uses magnitude, so a negative regime does not become funding income" do
    base = 6.hours.ago.change(min: 0)
    [-0.00003, -0.00002, -0.00001].each_with_index { |r, i| observe("XPP-20DEC30-CDE", r, base + i.hours) }

    rate = described_class.observed_fallback_rate(product_id: "XPP-20DEC30-CDE")

    expect(rate).to be_positive
    expect(rate).to be_within(1e-9).of(0.00002)
  end

  # Funding spikes are fat-tailed; one outlier hour must not set the rate for a
  # year of unobserved boundaries.
  it "uses the median, so a single spike does not set a year's rate" do
    base = 12.hours.ago.change(min: 0)
    ([0.00001] * 5 + [0.05]).each_with_index { |r, i| observe("ETP-20DEC30-CDE", r, base + i.hours) }

    expect(described_class.observed_fallback_rate(product_id: "ETP-20DEC30-CDE"))
      .to be < 0.0001
  end

  it "averages the middle pair on an even sample" do
    base = 6.hours.ago.change(min: 0)
    [0.00001, 0.00002, 0.00004, 0.00005].each_with_index { |r, i| observe("SLP-20DEC30-CDE", r, base + i.hours) }

    expect(described_class.observed_fallback_rate(product_id: "SLP-20DEC30-CDE"))
      .to be_within(1e-9).of(0.00003)
  end

  describe "as the Backtest::Engine default" do
    it "prefers the observed rate over the old 2.0 bps constant" do
      base = 6.hours.ago.change(min: 0)
      3.times { |i| observe("BIP-20DEC30-CDE", 0.00001, base + i.hours) }

      engine = Backtest::Engine.new(symbol: "BIP-20DEC30-CDE")
      rate = engine.instance_variable_get(:@funding_rate_per_interval)

      # 0.00001 = 0.1 bps, versus the old default of 2.0 bps.
      expect(rate).to be_within(1e-9).of(0.00001)
      expect(rate).to be < (Backtest::Engine::DEFAULT_FUNDING_BPS_PER_INTERVAL / 10_000.0)
    end

    it "still honours an explicit override" do
      base = 6.hours.ago.change(min: 0)
      3.times { |i| observe("BIP-20DEC30-CDE", 0.00001, base + i.hours) }

      engine = Backtest::Engine.new(symbol: "BIP-20DEC30-CDE", funding_bps_per_interval: 5.0)

      expect(engine.instance_variable_get(:@funding_rate_per_interval)).to be_within(1e-9).of(0.0005)
    end

    it "still allows funding to be disabled outright" do
      engine = Backtest::Engine.new(symbol: "BIP-20DEC30-CDE", funding_bps_per_interval: 0)

      expect(engine.instance_variable_get(:@funding_rate_per_interval)).to be_nil
    end
  end
end
