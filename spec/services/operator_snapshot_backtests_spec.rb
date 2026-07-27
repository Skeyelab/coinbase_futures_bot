# frozen_string_literal: true

require "rails_helper"

# Terminal read surface for persisted runs (#406/#408). The web UI is not always
# where an operator is; the CLI reads the same data through the same snapshot.
RSpec.describe OperatorSnapshot, "#backtests" do
  def run!(**overrides)
    BacktestRun.create!({
      symbol: "BIP-20DEC30-CDE", kind: "walk_forward", step: "5m",
      from_time: 30.days.ago, to_time: Time.current, status: "succeeded",
      fee_rate: 0.0003, metrics: {"expectancy" => 23.57, "cost_gate_passed" => true,
                                  "win_rate" => 0.46, "trade_count" => 153},
      equity_curve: Array.new(1_000) { |i| 10_000 + i },
      trades: [{"pnl" => 1.0}]
    }.merge(overrides))
  end

  before { BacktestRun.delete_all }

  it "returns runs newest first" do
    run!(symbol: "OLD-CDE", created_at: 2.days.ago)
    run!(symbol: "NEW-CDE")

    rows = described_class.new.backtests[:runs]

    expect(rows.first[:symbol]).to eq("NEW-CDE")
  end

  it "carries the gate verdict and headline metrics" do
    run!

    row = described_class.new.backtests[:runs].first

    expect(row).to include(cost_gate_passed: true, trade_count: 153, symbol: "BIP-20DEC30-CDE")
    expect(row[:expectancy]).to eq(23.57)
    expect(row[:fee_rate].to_f).to eq(0.0003)
  end

  # nil is "no verdict yet", which must not read as a failed gate.
  it "distinguishes no verdict from a failed gate" do
    run!(status: "running", metrics: nil)

    expect(described_class.new.backtests[:runs].first[:cost_gate_passed]).to be_nil
  end

  # Same sizing constraint as the index view: never ship the payload columns.
  it "does not load the heavy jsonb payloads" do
    run!

    expect { described_class.new.backtests[:runs] }.not_to raise_error
    expect(described_class.new.send(:backtest_scope).first.attributes).not_to include("equity_curve", "trades")
  end

  it "limits how many it returns" do
    3.times { run! }

    expect(described_class.new.backtests(limit: 2)[:runs].size).to eq(2)
  end
end
