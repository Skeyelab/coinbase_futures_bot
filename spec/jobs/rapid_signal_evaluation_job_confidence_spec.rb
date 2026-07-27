# frozen_string_literal: true

require "rails_helper"

# Issue #496. The bar was hardcoded at 75 — above the maximum the scorer has
# ever produced. Across a year of BIP history the strategy emitted 311 signals
# with max confidence 68.2 and p99 63.6, so the only path that places orders
# could not fire under any market condition.
RSpec.describe RapidSignalEvaluationJob, "confidence threshold", type: :job do
  it "defaults to a value inside the range the scorer can actually produce" do
    # Measured ceiling is ~68; anything at or above that is unreachable.
    expect(described_class.min_confidence).to be < 68.0
    expect(described_class.min_confidence).to be_positive
  end

  it "is configurable rather than hardcoded" do
    ClimateControl.modify(RSE_MIN_CONFIDENCE: "55") do
      expect(described_class.min_confidence).to eq(55.0)
    end
  end

  describe "gating" do
    let(:strategy) { instance_double(Strategy::MultiTimeframeSignal, last_rejection: nil) }
    let(:contract_manager) { instance_double(MarketData::FuturesContractManager) }
    let(:positions) { instance_double(Trading::CoinbasePositions) }
    let(:signal) { {side: "LONG", quantity: 1, confidence: 40, price: 64_000.0, tp: 65_280.0, sl: 63_232.0} }

    before do
      allow(Strategy::MultiTimeframeSignal).to receive(:new).and_return(strategy)
      allow(MarketData::FuturesContractManager).to receive(:new).and_return(contract_manager)
      allow(Trading::CoinbasePositions).to receive(:new).and_return(positions)
      allow(contract_manager).to receive(:current_month_contract).and_return("BIT-29AUG26-CDE")
      allow(strategy).to receive(:signal).and_return(signal)
      allow(Rails.application.config).to receive(:default_day_trading).and_return(true)
      Position.destroy_all
      SignalDecision.delete_all
      # About the confidence bar, not exposure — #437's cap has its own specs.
      allow(Trading::NotionalCap).to receive(:allows?).and_return(true)
    end

    def perform! = described_class.new.perform(product_id: "BTC-USD", current_price: 64_000.0, asset: "BTC")

    it "executes a signal that clears the measured bar" do
      expect(positions).to receive(:open_position).and_return({"success" => true})

      perform!
    end

    it "records the threshold it actually applied, not a literal" do
      ClimateControl.modify(RSE_MIN_CONFIDENCE: "55") do
        allow(positions).to receive(:open_position)
        perform!
      end

      d = SignalDecision.last
      expect(d.reason).to eq("low_confidence")
      expect(d.context["threshold"]).to eq(55.0)
    end
  end
end
