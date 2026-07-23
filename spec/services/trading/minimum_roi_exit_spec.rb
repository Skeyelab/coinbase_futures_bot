# frozen_string_literal: true

require "rails_helper"

# Issue #398 (ADR 0003): time-decaying take-profit. A {minutes_held => profit_ratio}
# schedule lowers the profit required to exit as a position ages, so stalled
# winners get booked instead of round-tripping to break-even. Pure decision
# function — tested table-style, like DollarExitPolicy.
RSpec.describe Trading::MinimumRoiExit, type: :service do
  # 0-19m: need 0.6%, 20-39m: 0.4%, 40-59m: 0.2%, 60m+: break-even (0%)
  let(:schedule) { {0 => 0.006, 20 => 0.004, 40 => 0.002, 60 => 0.0} }
  subject(:policy) { described_class.new(schedule) }

  describe "#threshold_for (decay curve)" do
    it "returns the value of the greatest scheduled minute <= minutes_held" do
      expect(policy.threshold_for(0)).to eq(0.006)
      expect(policy.threshold_for(19)).to eq(0.006)
      expect(policy.threshold_for(20)).to eq(0.004)
      expect(policy.threshold_for(45)).to eq(0.002)
      expect(policy.threshold_for(60)).to eq(0.0)
      expect(policy.threshold_for(600)).to eq(0.0)
    end

    it "returns nil when no scheduled minute is <= minutes_held" do
      p = described_class.new({10 => 0.01})
      expect(p.threshold_for(5)).to be_nil
    end
  end

  describe "#exit_reason" do
    it "exits (:time_decay_roi) once profit meets the decayed threshold" do
      # young position, small profit -> below 0.6% bar -> hold
      expect(policy.exit_reason(profit_ratio: 0.003, minutes_held: 5)).to be_nil
      # same profit after 20m -> bar dropped to 0.4% -> still hold
      expect(policy.exit_reason(profit_ratio: 0.003, minutes_held: 25)).to be_nil
      # after 40m -> bar 0.2% -> 0.3% profit books it
      expect(policy.exit_reason(profit_ratio: 0.003, minutes_held: 45)).to eq(:time_decay_roi)
    end

    it "books a flat/tiny winner once the bar decays to break-even" do
      expect(policy.exit_reason(profit_ratio: 0.0001, minutes_held: 10)).to be_nil
      expect(policy.exit_reason(profit_ratio: 0.0001, minutes_held: 65)).to eq(:time_decay_roi)
    end

    it "never triggers on a loss (profit below any positive threshold)" do
      expect(policy.exit_reason(profit_ratio: -0.01, minutes_held: 5)).to be_nil
      # at break-even bar (0.0), a losing position is still below 0 -> no exit
      expect(policy.exit_reason(profit_ratio: -0.01, minutes_held: 65)).to be_nil
    end

    it "returns nil before the schedule starts" do
      p = described_class.new({10 => 0.0})
      expect(p.exit_reason(profit_ratio: 0.5, minutes_held: 5)).to be_nil
    end

    it "handles a nil profit_ratio safely" do
      expect(policy.exit_reason(profit_ratio: nil, minutes_held: 45)).to be_nil
    end
  end

  describe "#enabled?" do
    it "is disabled for an empty schedule (inert by default, like DollarExitPolicy)" do
      expect(described_class.new({}).enabled?).to be false
      expect(policy.enabled?).to be true
    end
  end
end
