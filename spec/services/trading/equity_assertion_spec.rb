# frozen_string_literal: true

require "rails_helper"

# Issue #482: SignalEquity.usd defaults to $10,000, so funding a $1,000 account
# with SIGNAL_EQUITY_USD unset is a silent 10x oversizing on every trade.
RSpec.describe Trading::EquityAssertion, type: :service do
  let(:logger) { instance_double(ActiveSupport::Logger, warn: nil) }

  it "raises when the sizing figure is far from the real balance" do
    ClimateControl.modify(SIGNAL_EQUITY_USD: "10000") do
      expect { described_class.verify!(actual: 1_000.0, logger: logger) }
        .to raise_error(described_class::Divergence, /10x|900\.0%|\$10000\.00/)
    end
  end

  it "passes when they agree within tolerance" do
    ClimateControl.modify(SIGNAL_EQUITY_USD: "1000") do
      result = described_class.verify!(actual: 1_050.0, logger: logger)
      expect(result[:drift]).to be < 0.10
    end
  end

  it "raises just outside the tolerance band" do
    ClimateControl.modify(SIGNAL_EQUITY_USD: "1000") do
      expect { described_class.verify!(actual: 880.0, logger: logger) }
        .to raise_error(described_class::Divergence)
    end
  end

  it "honours a configured tolerance" do
    ClimateControl.modify(SIGNAL_EQUITY_USD: "1000", EQUITY_ASSERTION_TOLERANCE: "0.5") do
      expect { described_class.verify!(actual: 700.0, logger: logger) }.not_to raise_error
    end
  end

  # Degrade rather than block when the balance cannot be read — an unreachable
  # API must not become an outage.
  it "skips rather than raising when the balance is unavailable" do
    result = described_class.verify!(actual: 0.0, logger: logger)

    expect(result[:skipped]).to be true
    expect(logger).to have_received(:warn).with(/unavailable/)
  end
end
