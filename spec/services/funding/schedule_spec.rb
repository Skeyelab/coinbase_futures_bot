# frozen_string_literal: true

require "rails_helper"

RSpec.describe Funding::Schedule do
  # Hourly funding boundaries at 12:00 and 13:00 UTC for one product.
  let(:product_id) { "BTC-PERP-TESTS" }
  let(:noon) { Time.utc(2026, 7, 20, 12, 0, 0) }
  let(:one_pm) { Time.utc(2026, 7, 20, 13, 0, 0) }

  def observe(funding_time:, rate:, interval: 3600)
    FundingRate.create!(product_id: product_id, funding_time: funding_time, funding_rate: rate,
      funding_interval_seconds: interval, observed_at: funding_time)
  end

  describe "#funding_cost (signed, observed, per-boundary)" do
    before do
      observe(funding_time: noon, rate: 0.0001)   # +1 bp at 12:00
      observe(funding_time: one_pm, rate: 0.0003) # +3 bps at 13:00
    end

    let(:schedule) { described_class.for(product_id: product_id) }

    it "charges a long the sum of the observed rates it crosses" do
      # Hold 11:30 -> 13:30 crosses both boundaries: (1 bp + 3 bps) x 10_000 notional.
      cost = schedule.funding_cost(notional: 10_000.0, side: :buy,
        entry_time: noon - 1800, exit_time: one_pm + 1800)
      expect(cost).to be_within(1e-9).of((0.0001 + 0.0003) * 10_000.0)
    end

    it "credits a short the same magnitude with the opposite sign" do
      cost = schedule.funding_cost(notional: 10_000.0, side: :sell,
        entry_time: noon - 1800, exit_time: one_pm + 1800)
      expect(cost).to be_within(1e-9).of(-(0.0001 + 0.0003) * 10_000.0)
    end

    it "excludes the entry boundary and includes the exit boundary" do
      # Entry exactly at 12:00, exit exactly at 13:00 -> only the 13:00 boundary.
      cost = schedule.funding_cost(notional: 10_000.0, side: :buy,
        entry_time: noon, exit_time: one_pm)
      expect(cost).to be_within(1e-9).of(0.0003 * 10_000.0)
    end

    it "is zero for a hold that crosses no boundary" do
      cost = schedule.funding_cost(notional: 10_000.0, side: :buy,
        entry_time: noon + 60, exit_time: noon + 120)
      expect(cost).to eq(0.0)
    end
  end

  describe "#funding_cost fallback when history is missing" do
    let(:schedule) do
      described_class.for(product_id: product_id, constant_rate_per_interval: 0.0002,
        constant_interval_seconds: 3600)
    end

    it "falls back to the constant and logs (never silent)" do
      logger = instance_double(Logger)
      allow(logger).to receive(:warn)
      sched = described_class.new(product_id: product_id, observations: [],
        constant_rate_per_interval: 0.0002, constant_interval_seconds: 3600, logger: logger)

      cost = sched.funding_cost(notional: 10_000.0, side: :buy,
        entry_time: noon - 1800, exit_time: one_pm + 1800)

      expect(cost).to be_within(1e-9).of(2 * 0.0002 * 10_000.0) # two boundaries at 2 bps
      expect(logger).to have_received(:warn).with(/fell back to the constant/)
    end

    it "treats funding as free when there is neither history nor a constant" do
      sched = described_class.new(product_id: product_id, observations: [], constant_rate_per_interval: nil)
      expect(sched).not_to be_active
      expect(sched.funding_cost(notional: 10_000.0, side: :buy,
        entry_time: noon - 1800, exit_time: one_pm + 1800)).to eq(0.0)
    end
  end

  describe "#expected_forward_rate (magnitude, for the gate)" do
    it "returns the magnitude of the most recent observation at/before as_of" do
      observe(funding_time: noon, rate: -0.0005) # negative rate; gate uses magnitude
      schedule = described_class.for(product_id: product_id)
      expect(schedule.expected_forward_rate(as_of: one_pm)).to be_within(1e-12).of(0.0005)
    end

    it "falls back to the constant magnitude before any history exists" do
      schedule = described_class.new(product_id: product_id, observations: [], constant_rate_per_interval: 0.0002)
      expect(schedule.expected_forward_rate(as_of: noon)).to be_within(1e-12).of(0.0002)
    end
  end
end
