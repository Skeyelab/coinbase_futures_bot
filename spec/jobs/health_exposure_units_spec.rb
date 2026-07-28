# frozen_string_literal: true

require "rails_helper"

# Issue #536: the exposure limits read as fractions (0.5 = 50%) but were compared
# against HealthCheckJob#exposure_percent, which already multiplies by 100 — so
# the real ceiling was half of one percent, and every ordinary position tripped it.
RSpec.describe "health exposure thresholds are in percent (issue #536)" do
  let(:cfg) { Rails.application.config.monitoring_config }

  it "expresses the limits in the same units as exposure_percent" do
    # exposure_percent returns e.g. 7.89 for 7.89%. A limit below 1 would mean
    # under one percent of equity, which is less than a single contract.
    expect(cfg[:max_day_trading_exposure]).to be > 1.0
    expect(cfg[:max_swing_trading_exposure]).to be > 1.0
  end

  it "sets a ceiling that a real position can actually satisfy" do
    equity = 10_072.27
    allowed = equity * cfg[:max_day_trading_exposure] / 100.0
    # The position that was tripping it on 2026-07-28 was $794.50 of notional.
    expect(allowed).to be > 794.50
  end

  it "stays well under the cap that is actually enforced" do
    # Trading::NotionalCap blocks orders above multiple x equity. An advisory
    # warning above the enforced limit could never fire first.
    enforced_percent = Trading::NotionalCap::DEFAULT_MULTIPLE.to_f * 100
    expect(cfg[:max_day_trading_exposure]).to be < enforced_percent
  end

  describe "the check itself" do
    let(:job) { HealthCheckJob.new }

    it "does not warn on an ordinary single position" do
      allow(job).to receive(:calculate_day_trading_exposure).and_return(7.89)
      allow(job).to receive(:calculate_swing_trading_exposure).and_return(0.0)

      result = job.send(:check_portfolio_exposure)

      expect(result[:healthy]).to be(true)
      expect(result[:warnings]).to be_empty
    end

    it "still warns when exposure is genuinely high" do
      # 3 positions on 2026-07-28 were $7,165 notional on ~$10k equity.
      allow(job).to receive(:calculate_day_trading_exposure).and_return(71.6)
      allow(job).to receive(:calculate_swing_trading_exposure).and_return(0.0)

      result = job.send(:check_portfolio_exposure)

      expect(result[:healthy]).to be(false)
      expect(result[:warnings].first).to match(/Day trading exposure: 71.6%/)
    end
  end
end
