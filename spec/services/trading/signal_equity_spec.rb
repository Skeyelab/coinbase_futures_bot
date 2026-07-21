# frozen_string_literal: true

require "rails_helper"

# Issue #375: SIGNAL_EQUITY_USD was read with default "50000" in the
# executor but "10000" everywhere else — a silent 5x sizing skew whenever
# the env var was unset. One source of truth now.
RSpec.describe Trading::SignalEquity, type: :service do
  it "defaults to $10,000" do
    ClimateControl.modify(SIGNAL_EQUITY_USD: nil) do
      expect(described_class.usd).to eq(10_000.0)
    end
  end

  it "honors the env override" do
    ClimateControl.modify(SIGNAL_EQUITY_USD: "25000") do
      expect(described_class.usd).to eq(25_000.0)
    end
  end
end
