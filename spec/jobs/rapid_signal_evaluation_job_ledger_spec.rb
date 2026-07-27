# frozen_string_literal: true

require "rails_helper"

# Issue #480. Every skip used to be a logger.debug that rolled off, so "3 trades
# in 10 days" was never a measurement — it was an absence of one. Nothing could
# distinguish "the strategy found nothing" from "one gate rejected thousands".
RSpec.describe RapidSignalEvaluationJob, "decision ledger", type: :job do
  let(:contract_id) { "BIT-29AUG25-CDE" }
  let(:strategy) { instance_double(Strategy::MultiTimeframeSignal) }
  let(:contract_manager) { instance_double(MarketData::FuturesContractManager) }
  let(:positions) { instance_double(Trading::CoinbasePositions) }
  let(:signal) { {side: "LONG", quantity: 1, confidence: 90, price: 50_000.0, tp: 50_300.0, sl: 49_800.0} }

  before do
    allow(Strategy::MultiTimeframeSignal).to receive(:new).and_return(strategy)
    allow(MarketData::FuturesContractManager).to receive(:new).and_return(contract_manager)
    allow(Trading::CoinbasePositions).to receive(:new).and_return(positions)
    allow(contract_manager).to receive(:current_month_contract).and_return(contract_id)
    allow(strategy).to receive(:signal).and_return(signal)
    allow(strategy).to receive(:last_rejection).and_return(nil)
    allow(Rails.application.config).to receive(:default_day_trading).and_return(true)
    Position.destroy_all
    SignalDecision.delete_all
    Trading::ProtectionLock.clear!
  end

  after { Trading::ProtectionLock.clear! }

  def perform!
    described_class.new.perform(product_id: "BTC-USD", current_price: 50_000.0, asset: "BTC")
  end

  it "records a traded decision with lineage to the position" do
    position = create(:position)
    allow(positions).to receive(:open_position)
      .and_return({"success" => true, "position_id" => position.id})

    expect { perform! }.to change(SignalDecision.traded, :count).by(1)

    d = SignalDecision.last
    expect(d.reason).to eq("traded")
    expect(d.position_id).to eq(position.id)
    expect(d.contract_id).to eq(contract_id)
  end

  # The reason that matters most: an undifferentiated "no signal" bucket cannot
  # tell an over-selective strategy from a data-starved one.
  it "carries the strategy's own rejection reason through" do
    allow(strategy).to receive(:signal).and_return(nil)
    allow(strategy).to receive(:last_rejection).and_return(:insufficient_1m_candles)

    perform!

    d = SignalDecision.last
    expect(d.reason).to eq("strategy_no_signal")
    expect(d.context["strategy_reason"]).to eq("insufficient_1m_candles")
  end

  it "records the gate that stopped a signal" do
    # Below the measured bar (#496), which is well under the old literal 75.
    allow(strategy).to receive(:signal)
      .and_return(signal.merge(confidence: described_class.min_confidence - 1))

    perform!

    expect(SignalDecision.last.reason).to eq("low_confidence")
    expect(SignalDecision.last.context["threshold"]).to eq(described_class.min_confidence)
  end

  it "records a protection block distinctly from a confidence rejection" do
    Trading::ProtectionLock.add(source: "stoploss_guard", scope: "global", side: "both",
      reason: "loss cluster", expires_at: 1.hour.from_now)

    perform!

    expect(SignalDecision.last.reason).to eq("protection_active")
    expect(SignalDecision.last.context["protection"]).to include("stoploss_guard")
  end

  it "records a suspended symbol without evaluating a strategy" do
    allow(Trading::SymbolSuspension).to receive(:suspended?).and_return(true)
    allow(Trading::SymbolSuspension).to receive(:all).and_return({"BTC-USD" => {"reason" => "manual"}})

    perform!

    expect(SignalDecision.last.reason).to eq("symbol_suspended")
  end

  it "records a failed order rather than silently dropping it" do
    allow(positions).to receive(:open_position).and_return({"success" => false, "error" => "rejected"})

    perform!

    expect(SignalDecision.last.reason).to eq("order_failed")
    expect(SignalDecision.last.context["error"]).to eq("rejected")
  end

  it "produces a histogram that names the binding gate" do
    allow(strategy).to receive(:signal)
      .and_return(signal.merge(confidence: described_class.min_confidence - 1))
    3.times { perform! }

    expect(SignalDecision.rejection_histogram(product_id: "BTC-USD"))
      .to eq({"low_confidence" => 3})
  end
end
