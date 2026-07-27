# frozen_string_literal: true

require "rails_helper"

RSpec.describe BacktestRun do
  def build_run(**overrides)
    described_class.new({
      symbol: "BTC-USD",
      kind: "single",
      step: "5m",
      from_time: 30.days.ago,
      to_time: Time.current,
      status: "succeeded",
      metrics: {"expectancy" => 1.25, "cost_gate_passed" => true, "win_rate" => 0.6,
                "max_drawdown" => 0.08, "trade_count" => 12, "total_fees" => 3.4}
    }.merge(overrides))
  end

  # Views should read a headline metric without knowing it lives in a jsonb
  # blob, and without caring whether the key arrives as a string or a symbol.
  it "delegates headline metrics to the stored payload" do
    run = build_run

    expect(run.expectancy).to eq(1.25)
    expect(run.cost_gate_passed).to be(true)
    expect(run.trade_count).to eq(12)
  end

  it "reads metrics assigned in-process, before any database round trip" do
    run = build_run(metrics: {expectancy: 2.5})

    expect(run.expectancy).to eq(2.5)
  end

  it "returns nil for a metric the payload does not carry" do
    expect(build_run(metrics: {}).sharpe_like).to be_nil
    expect(build_run(metrics: nil).expectancy).to be_nil
  end

  it "rejects a kind or status outside the known set" do
    expect(build_run(kind: "sideways")).not_to be_valid
    expect(build_run(status: "halfway")).not_to be_valid
    expect(build_run).to be_valid
  end

  it "reports duration only once the run has finished" do
    started = Time.current
    expect(build_run(started_at: started, finished_at: started + 90).duration).to eq(90)
    expect(build_run(started_at: started, finished_at: nil).duration).to be_nil
  end

  describe "scopes" do
    before do
      build_run(symbol: "OIL-USD", status: "failed").save!
      build_run(symbol: "BTC-USD", status: "succeeded").save!
    end

    it "filters by symbol and status, newest first" do
      expect(described_class.for_symbol("OIL-USD").count).to eq(1)
      expect(described_class.succeeded.pluck(:symbol)).to eq(["BTC-USD"])
      expect(described_class.recent.first.created_at).to be >= described_class.recent.last.created_at
    end
  end
end
