# frozen_string_literal: true

require "rails_helper"

# ADR 0006 decision 3: admission requires a PASSED GATE, not an absence of
# objection. `backtest_runs.metrics->>'cost_gate_passed'` has held the verdict
# since #406 and nothing read it, so a symbol reached the order path on operator
# judgement alone — the "no evidence inheritance" rule ADR 0002 states but never
# had a mechanism for.
#
# The sample-size floor is not decoration. On 2026-07-29 the recorded runs for
# BIP-20DEC30-CDE looked like this:
#
#   07-27  gate=true   expectancy +48.64   trades=2
#   07-27  gate=true   expectancy +29.15   trades=2
#   07-29  gate=false  expectancy  -3.45   trades=4644
#   07-29  gate=false  expectancy  -3.15   trades=3142
#
# Every PASS rested on two trades; every FAIL rested on thousands and agreed to
# within a dollar. A gate that reads `cost_gate_passed` alone would have admitted
# BIP on +$48.64-from-two-trades and called it evidence. #376 gate 2 already
# demands >=100 trades/symbol; this inherits that rather than laundering noise
# into permission.
RSpec.describe RapidSignalEvaluationJob, "cost-gate verdict (ADR 0006 decision 3)", type: :job do
  let(:contract_id) { "BIP-20DEC30-CDE" }
  let(:strategy) { instance_double(Strategy::MultiTimeframeSignal, last_rejection: nil) }
  let(:contract_manager) { instance_double(MarketData::FuturesContractManager) }
  let(:positions) { instance_double(Trading::CoinbasePositions) }
  let(:signal) { {side: "LONG", quantity: 1, confidence: 90, price: 650.0, tp: 663.0, sl: 642.2} }

  before do
    allow(Strategy::MultiTimeframeSignal).to receive(:new).and_return(strategy)
    allow(MarketData::FuturesContractManager).to receive(:new).and_return(contract_manager)
    allow(Trading::CoinbasePositions).to receive(:new).and_return(positions)
    allow(contract_manager).to receive(:best_available_contract).and_return(contract_id)
    allow(strategy).to receive(:signal).and_return(signal)
    allow(Trading::ContractSizeResolver).to receive(:for_product).and_return(1.0)
    allow(Trading::CurrentEquity).to receive(:usd).and_return(1_000.0)
    allow(Rails.application.config).to receive(:default_day_trading).and_return(true)
    allow(described_class).to receive(:max_live_instruments).and_return(10)
    Position.destroy_all
    SignalDecision.delete_all
    BacktestRun.delete_all
  end

  def perform! = described_class.new.perform(product_id: "BTC-USD", current_price: 650.0, asset: "BTC")

  def record_run(passed:, trades:, at: Time.current, status: "succeeded")
    BacktestRun.create!(
      symbol: contract_id, kind: "walk_forward", step: "5m", status: status,
      from_time: 30.days.ago, to_time: Time.current, created_at: at,
      metrics: {"cost_gate_passed" => passed, "trade_count" => trades}
    )
  end

  it "refuses a symbol with no recorded verdict at all" do
    expect(positions).not_to receive(:open_position)

    perform!

    expect(SignalDecision.last.reason).to eq("cost_gate_unproven")
  end

  # The real 07-27 runs: gate=true on expectancy +$48.64 from TWO trades.
  it "refuses a pass that rests on too few trades to be evidence" do
    record_run(passed: true, trades: 2)

    expect(positions).not_to receive(:open_position)

    perform!

    expect(SignalDecision.last.reason).to eq("cost_gate_unproven")
  end

  it "admits a symbol whose latest walk-forward cleared the gate on enough trades" do
    record_run(passed: true, trades: 500)

    expect(positions).to receive(:open_position).and_return({"success" => true})

    perform!
  end

  # The exact shape of BIP on 2026-07-29: older passes, then fresh failures on
  # far more trades. Taking "any pass ever" would trade on the stale one.
  it "lets the latest verdict supersede an older pass" do
    record_run(passed: true, trades: 500, at: 3.days.ago)
    record_run(passed: false, trades: 4644, at: 1.hour.ago)

    expect(positions).not_to receive(:open_position)

    perform!

    expect(SignalDecision.last.reason).to eq("cost_gate_unproven")
  end

  # A run still in flight, or one that crashed, is not a verdict.
  it "ignores runs that did not succeed" do
    record_run(passed: true, trades: 500, status: "running")

    expect(positions).not_to receive(:open_position)

    perform!

    expect(SignalDecision.last.reason).to eq("cost_gate_unproven")
  end

  it "records why it refused, not merely that it did" do
    record_run(passed: true, trades: 2)

    perform!

    ctx = SignalDecision.last.context || {}
    expect(ctx.to_json).to include("2")
  end
end
