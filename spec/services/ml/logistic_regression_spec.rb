# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ml::LogisticRegression do
  describe ".fit" do
    it "recovers the sign of a cleanly separable 1-D pattern" do
      xs = [[-2.0], [-1.5], [-1.0], [-0.5], [0.5], [1.0], [1.5], [2.0]]
      ys = [0, 0, 0, 0, 1, 1, 1, 1]

      model = described_class.fit(xs, ys)

      expect(model.weights.first).to be > 0
      expect(model.predict_probability([2.0])).to be > 0.9
      expect(model.predict_probability([-2.0])).to be < 0.1
    end

    it "flips the coefficient sign when the pattern is mirrored" do
      xs = [[-2.0], [-1.0], [1.0], [2.0]]
      up = described_class.fit(xs, [0, 0, 1, 1])
      down = described_class.fit(xs, [1, 1, 0, 0])

      expect(up.weights.first).to be > 0
      expect(down.weights.first).to be < 0
      expect(down.weights.first).to be_within(1e-6).of(-up.weights.first)
    end

    it "recovers per-feature signs on a two-feature pattern" do
      # y follows x1 positively and x2 negatively; the grid is balanced so
      # neither feature can proxy for the other.
      xs = [
        [1.0, -1.0], [1.0, 1.0], [-1.0, -1.0], [-1.0, 1.0],
        [2.0, -2.0], [2.0, 2.0], [-2.0, -2.0], [-2.0, 2.0]
      ]
      ys = [1, 1, 0, 0, 1, 0, 1, 0]

      model = described_class.fit(xs, ys)

      expect(model.weights[0]).to be > 0
      expect(model.weights[1]).to be < 0
    end

    it "fits the base rate exactly when the feature carries no signal (hand-checkable)" do
      # Both feature groups have identical 25% positive rate, so the exact
      # maximum-likelihood solution is weight 0, intercept logit(0.25).
      xs = [[1.0]] * 4 + [[-1.0]] * 4
      ys = [1, 0, 0, 0, 1, 0, 0, 0]

      model = described_class.fit(xs, ys)

      expect(model.weights.first.abs).to be < 0.01
      expect(model.intercept).to be_within(0.01).of(Math.log(0.25 / 0.75))
      expect(model.predict_probability([1.0])).to be_within(0.01).of(0.25)
    end

    it "is deterministic: the same data always yields the same coefficients" do
      xs = [[0.2, 1.0], [0.4, -1.0], [-0.3, 0.5], [0.9, -0.2], [-0.8, 0.1], [0.1, 0.7]]
      ys = [1, 1, 0, 1, 0, 0]

      a = described_class.fit(xs, ys)
      b = described_class.fit(xs, ys)

      expect(a.intercept).to eq(b.intercept)
      expect(a.weights).to eq(b.weights)
    end

    it "remains bounded on perfectly separable data (ridge keeps it finite)" do
      xs = [[-1.0], [1.0]]
      model = described_class.fit(xs, [0, 1])

      expect(model.weights.first).to be_finite
      expect(model.intercept).to be_finite
    end

    it "rejects mismatched row/target lengths" do
      expect { described_class.fit([[1.0]], [1, 0]) }.to raise_error(ArgumentError)
    end

    it "rejects empty datasets" do
      expect { described_class.fit([], []) }.to raise_error(ArgumentError)
    end
  end

  describe "#predict_probability" do
    it "computes the logistic of the linear score (hand-checkable)" do
      model = described_class.new(intercept: -1.0, weights: [2.0, -0.5])

      # eta = -1 + 2*1 - 0.5*2 = 0.0 -> p = 0.5
      expect(model.predict_probability([1.0, 2.0])).to be_within(1e-12).of(0.5)
      # eta = -1 + 2*0.5 - 0.5*0 = 0 -> 0.5; eta = 1 -> 1/(1+e^-1)
      expect(model.predict_probability([1.0, 0.0])).to be_within(1e-9).of(1.0 / (1.0 + Math.exp(-1.0)))
    end
  end
end
