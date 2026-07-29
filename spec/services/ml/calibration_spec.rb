# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ml::Calibration do
  describe ".decile_report" do
    it "splits by predicted probability and reports predicted vs realized per decile (hand-checkable)" do
      # 20 observations: predictions 0.05, 0.10, ..., 1.00. Outcome = 1 for the
      # top five predictions only, so realized rates are exactly computable.
      predictions = (1..20).map { |i| i / 20.0 }
      outcomes = (1..20).map { |i| (i > 15) ? 1 : 0 }

      report = described_class.decile_report(predictions, outcomes)

      expect(report.size).to eq(10)
      expect(report.sum { |row| row[:n] }).to eq(20)
      expect(report.map { |row| row[:n] }).to all(eq(2))

      bottom = report.first
      expect(bottom[:decile]).to eq(1)
      expect(bottom[:mean_predicted]).to be_within(1e-9).of(0.075) # (0.05+0.10)/2
      expect(bottom[:realized_rate]).to eq(0.0)

      top = report.last
      expect(top[:decile]).to eq(10)
      expect(top[:mean_predicted]).to be_within(1e-9).of(0.975)
      expect(top[:realized_rate]).to eq(1.0)

      ninth = report[8] # predictions 0.85, 0.90 -> outcomes 1, 1
      expect(ninth[:realized_rate]).to eq(1.0)
      eighth = report[7] # predictions 0.75, 0.80 -> outcomes 0, 1
      expect(eighth[:realized_rate]).to eq(0.5)
    end

    it "keeps decile sizes within one of each other when n is not divisible by 10" do
      predictions = (1..23).map { |i| i / 23.0 }
      outcomes = [0] * 23

      sizes = described_class.decile_report(predictions, outcomes).map { |row| row[:n] }

      expect(sizes.sum).to eq(23)
      expect(sizes.max - sizes.min).to be <= 1
    end

    it "raises on mismatched lengths" do
      expect { described_class.decile_report([0.5], []) }.to raise_error(ArgumentError)
    end
  end

  describe ".cutoff_sweep" do
    it "reports selection size and realized win rate at each cutoff" do
      predictions = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8]
      outcomes = [0, 0, 0, 1, 0, 1, 1, 1]

      sweep = described_class.cutoff_sweep(predictions, outcomes, cutoffs: [0.35, 0.55, 0.75])

      expect(sweep[0]).to include(cutoff: 0.35, n: 5, realized_rate: 0.8)
      expect(sweep[1]).to include(cutoff: 0.55, n: 3, realized_rate: 1.0)
      expect(sweep[2]).to include(cutoff: 0.75, n: 1, realized_rate: 1.0)
    end

    it "reports zero-selection cutoffs with a nil rate instead of dividing by zero" do
      sweep = described_class.cutoff_sweep([0.2], [1], cutoffs: [0.9])

      expect(sweep[0]).to include(cutoff: 0.9, n: 0, realized_rate: nil)
    end
  end

  describe ".operating_point" do
    it "returns the lowest cutoff whose realized rate clears the bar" do
      predictions = [0.1, 0.3, 0.45, 0.5, 0.62, 0.7]
      outcomes = [0, 0, 0, 1, 1, 1]

      point = described_class.operating_point(predictions, outcomes,
        target_rate: 0.40, cutoffs: [0.2, 0.4, 0.6])

      # cutoff 0.2 -> 5 selected, 3 wins = 0.6 >= 0.4: the LOWEST clearing cutoff wins
      expect(point).to include(cutoff: 0.2, n: 5, realized_rate: 0.6)
    end

    it "returns nil when no cutoff clears the bar" do
      point = described_class.operating_point([0.5, 0.6], [0, 0],
        target_rate: 0.40, cutoffs: [0.4, 0.55])

      expect(point).to be_nil
    end
  end
end
