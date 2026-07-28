# frozen_string_literal: true

require "rails_helper"

# Issue #437: the count caps bound how MANY positions, not how much exposure.
# This is the only check that sees the stack across concurrent positions.
RSpec.describe RapidSignalEvaluationJob, "account notional cap", type: :job do
  let(:contract_id) { "BIP-20DEC30-CDE" }
  let(:strategy) { instance_double(Strategy::MultiTimeframeSignal, last_rejection: nil) }
  let(:contract_manager) { instance_double(MarketData::FuturesContractManager) }
  let(:positions) { instance_double(Trading::CoinbasePositions) }
  let(:signal) { {side: "LONG", quantity: 1, confidence: 90, price: 650.0, tp: 663.0, sl: 642.2} }

  before do
    allow(Strategy::MultiTimeframeSignal).to receive(:new).and_return(strategy)
    allow(MarketData::FuturesContractManager).to receive(:new).and_return(contract_manager)
    allow(Trading::CoinbasePositions).to receive(:new).and_return(positions)
    allow(contract_manager).to receive(:current_month_contract).and_return(contract_id)
    allow(strategy).to receive(:signal).and_return(signal)
    allow(Trading::ContractSizeResolver).to receive(:for_product).and_return(1.0)
    allow(Trading::CurrentEquity).to receive(:usd).and_return(1_000.0)
    allow(Rails.application.config).to receive(:default_day_trading).and_return(true)
    # ADR 0006's MAX_LIVE_INSTRUMENTS is not the gate under test here. These
    # examples stand several instruments up so that a DIFFERENT cap is the one
    # that binds; the universe cap has its own spec.
    allow(described_class).to receive(:max_live_instruments).and_return(10)
    Position.destroy_all
    SignalDecision.delete_all
  end

  def perform! = described_class.new.perform(product_id: "BTC-USD", current_price: 650.0, asset: "BTC")

  it "opens when the entry fits under the cap" do
    expect(positions).to receive(:open_position).and_return({"success" => true})

    perform!
  end

  # The failure mode the issue was filed for: each position is small, the SUM
  # is not, and no per-position check can see it.
  it "refuses once concurrent positions have consumed the cap" do
    create(:position, product_id: "NOL-19AUG26-CDE", size: 1, entry_price: 1_000.0, status: "OPEN")
    create(:position, product_id: "BIT-29AUG26-CDE", size: 1, entry_price: 1_000.0, status: "OPEN")

    expect(positions).not_to receive(:open_position)

    perform!
    expect(SignalDecision.last.reason).to eq("account_notional_cap")
  end

  it "records the exposure that caused the refusal" do
    create(:position, product_id: "NOL-19AUG26-CDE", size: 2, entry_price: 1_000.0, status: "OPEN")
    allow(positions).to receive(:open_position)

    perform!

    ctx = SignalDecision.last.context
    expect(ctx["open_notional"]).to be_present
    expect(ctx["limit"]).to eq(2_000.0)
  end
end
