# frozen_string_literal: true

require "rails_helper"

# Issue #398: schedule resolves from config — a global default plus per-symbol
# overrides — and is inert (empty) by default so behavior is unchanged until an
# operator opts in.
RSpec.describe Trading::MinimumRoiExit, ".from_config" do
  def with_config(cfg)
    orig = Rails.application.config.real_time_signals
    Rails.application.config.real_time_signals = orig.merge(min_roi: cfg)
    yield
  ensure
    Rails.application.config.real_time_signals = orig
  end

  it "is inert when no min_roi config is present" do
    with_config(nil) do
      expect(described_class.from_config(symbol: "BTC-USD").enabled?).to be false
    end
  end

  it "uses the global schedule when no per-symbol override exists" do
    with_config({schedule: {0 => 0.006, 60 => 0.0}}) do
      policy = described_class.from_config(symbol: "BTC-USD")
      expect(policy.enabled?).to be true
      expect(policy.threshold_for(0)).to eq(0.006)
    end
  end

  it "prefers a per-symbol override over the global schedule" do
    with_config({schedule: {0 => 0.006}, per_symbol: {"ETH-USD" => {0 => 0.009}}}) do
      expect(described_class.from_config(symbol: "ETH-USD").threshold_for(0)).to eq(0.009)
      expect(described_class.from_config(symbol: "BTC-USD").threshold_for(0)).to eq(0.006)
    end
  end
end
