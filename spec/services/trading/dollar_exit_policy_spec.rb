# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trading::DollarExitPolicy do
  describe ".from_env" do
    it "is disabled when neither threshold is configured" do
      policy = ClimateControl.modify(DOLLAR_PROFIT_TARGET_USD: nil, DOLLAR_STOP_LOSS_USD: nil) do
        described_class.from_env
      end

      expect(policy.enabled?).to be(false)
    end

    it "is enabled when a profit target is configured" do
      policy = ClimateControl.modify(DOLLAR_PROFIT_TARGET_USD: "30", DOLLAR_STOP_LOSS_USD: nil) do
        described_class.from_env
      end

      expect(policy.enabled?).to be(true)
    end
  end

  describe "#exit_reason" do
    subject(:policy) { described_class.new(profit_target: 30.0, stop_loss: 25.0) }

    it "returns :dollar_target when unrealized PnL reaches the profit target" do
      expect(policy.exit_reason(30.0)).to eq(:dollar_target)
      expect(policy.exit_reason(41.5)).to eq(:dollar_target)
    end

    it "returns :dollar_stop_loss when unrealized PnL falls to the stop" do
      expect(policy.exit_reason(-25.0)).to eq(:dollar_stop_loss)
      expect(policy.exit_reason(-60.0)).to eq(:dollar_stop_loss)
    end

    it "returns nil inside the band" do
      expect(policy.exit_reason(10.0)).to be_nil
      expect(policy.exit_reason(-10.0)).to be_nil
    end

    it "returns nil for a nil PnL (no price available)" do
      expect(policy.exit_reason(nil)).to be_nil
    end

    it "only applies the configured threshold when the other is absent" do
      profit_only = described_class.new(profit_target: 30.0, stop_loss: nil)
      expect(profit_only.exit_reason(-500.0)).to be_nil
      expect(profit_only.exit_reason(30.0)).to eq(:dollar_target)

      stop_only = described_class.new(profit_target: nil, stop_loss: 25.0)
      expect(stop_only.exit_reason(500.0)).to be_nil
      expect(stop_only.exit_reason(-25.0)).to eq(:dollar_stop_loss)
    end
  end
end
