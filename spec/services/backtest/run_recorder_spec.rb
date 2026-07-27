# frozen_string_literal: true

require "rails_helper"

RSpec.describe Backtest::RunRecorder, type: :service do
  let(:from) { Time.parse("2026-06-01T00:00:00Z") }
  let(:to) { Time.parse("2026-07-01T00:00:00Z") }

  # A strategy that never signals: the recorder is being tested, not the engine.
  def silent_strategy
    Class.new do
      def signal(symbol:, equity_usd:, as_of: nil) = nil
    end.new
  end

  def engine(**overrides)
    Backtest::Engine.new(symbol: "BTC-USD", strategy: silent_strategy, step: "5m", **overrides)
  end

  def result_with(trades:, equity_curve: [10_000.0, 10_050.0])
    Backtest::Result.new(trades: trades, equity_curve: equity_curve,
      starting_equity: 10_000.0, from: from, to: to)
  end

  let(:trade) do
    {side: "LONG", entry_price: 60_000.0, exit_price: 60_500.0, quantity: 1.0,
     pnl: 50.0, fees: 3.0, entered_at: from, exited_at: from + 1.hour}
  end

  # The engine resolves fee_rate from CostModel when passed nil. Storing nil
  # would let a historical run re-interpret itself under whatever the env says
  # later, which silently destroys comparability across the ADR 0002 venue
  # change — so the resolved value has to land in the row.
  it "records the resolved inputs rather than the caller's nils" do
    run = described_class.record_single(engine: engine, result: result_with(trades: [trade]))

    expect(run).to be_persisted
    expect(run.fee_rate).to be_present
    expect(run.fee_rate.to_f).to eq(CostModel.fee_for("BTC-USD")[:taker_rate].to_f)
    expect(run.contract_size_usd).to be_present
    expect(run.symbol).to eq("BTC-USD")
    expect(run.step).to eq("5m")
    expect(run.kind).to eq("single")
    expect(run.status).to eq("succeeded")
  end

  # Metrics must be the CLI's own numbers, not a second derivation that can
  # drift from Result#to_h.
  it "round-trips the metrics Result computed" do
    result = result_with(trades: [trade])
    run = described_class.record_single(engine: engine, result: result)

    expect(run.reload.expectancy).to eq(result.expectancy)
    expect(run.total_fees).to eq(result.total_fees)
    expect(run.win_rate).to eq(result.win_rate)
    expect(run.cost_gate_passed).to eq(result.cost_gate_passed)
    expect(run.trade_count).to eq(1)
  end

  it "splits the trade list out of the metrics blob" do
    run = described_class.record_single(engine: engine, result: result_with(trades: [trade])).reload

    expect(run.metrics).not_to have_key("trades")
    expect(run.trades.size).to eq(1)
    expect(run.trades.first["pnl"]).to eq(50.0)
    expect(run.equity_curve).to eq([10_000.0, 10_050.0])
  end

  it "records a walk-forward report with its per-window detail" do
    report = {
      windows: [{from: from, to: to, metrics: {total_pnl: 12.0}, data_coverage: 0.98}],
      aggregate: {window_count: 1, profitable_windows: 1}
    }

    run = described_class.record_walk_forward(
      engine: engine, report: report, from: from, to: to, train_days: 14, eval_days: 7
    ).reload

    expect(run.kind).to eq("walk_forward")
    expect(run.train_days).to eq(14)
    expect(run.eval_days).to eq(7)
    expect(run.windows.first["data_coverage"]).to eq(0.98)
    expect(run.metrics["window_count"]).to eq(1)
  end

  # A run that raised must still leave a trace; otherwise failures reproduce the
  # write-only hole this issue closes.
  it "records a failed run with its error" do
    run = described_class.record_failure(
      engine: engine, from: from, to: to, kind: "single",
      error: ArgumentError.new("unknown step")
    )

    expect(run.status).to eq("failed")
    expect(run.error_message).to include("ArgumentError", "unknown step")
  end

  it "omits the heavy payloads from index-view queries" do
    described_class.record_single(engine: engine, result: result_with(trades: [trade]))

    row = BacktestRun.without_payloads.recent.first

    expect(row.expectancy).to eq(50.0)
    expect { row.trades }.to raise_error(ActiveModel::MissingAttributeError)
    expect { row.equity_curve }.to raise_error(ActiveModel::MissingAttributeError)
  end

  # Issue #471: fee_rate alone is a lossy projection of the venue's fee shape.
  # A stored run has to carry the per-contract floor or it cannot be re-costed
  # faithfully — which is exactly what the #408/#409 re-costing UI will do.
  it "records the whole fee shape, not just the rate" do
    run = described_class.record_single(engine: engine, result: result_with(trades: [trade])).reload

    expect(run.fee_rate.to_f).to eq(CostModel.fee_for("BTC-USD")[:taker_rate].to_f)
    expect(run.per_contract_fee.to_f).to eq(CostModel.fee_for("BTC-USD")[:per_contract_fee].to_f)
  end

  it "reproduces the engine's costing from the stored row alone" do
    run = described_class.record_single(engine: engine, result: result_with(trades: [trade])).reload

    rebuilt = Backtest::Engine.new(symbol: run.symbol, strategy: silent_strategy, step: run.step,
      fee_rate: run.fee_rate, per_contract_fee: run.per_contract_fee,
      contract_size_usd: run.contract_size_usd, starting_equity: run.starting_equity)

    expect(rebuilt.fee_rate).to eq(run.fee_rate.to_f)
    expect(rebuilt.per_contract_fee).to eq(run.per_contract_fee.to_f)
    expect(rebuilt.contract_size_usd).to eq(run.contract_size_usd.to_f)
  end
end
