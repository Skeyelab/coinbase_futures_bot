# frozen_string_literal: true

require "rails_helper"

# Issue #299 (closes #163): calibration evaluates the LIVE strategy
# (MultiTimeframeSignal) through the walk-forward backtest engine and
# persists the winning params to a versioned, per-symbol TradingProfile.
RSpec.describe CalibrationJob, type: :job do
  let(:t0) { Time.parse("2026-03-01T00:00:00Z") }

  before { travel_to t0 }
  after { travel_back }

  def insert_step_candles(symbol, count: 120)
    Candle.insert_all!(Array.new(count) do |i|
      {symbol: symbol, timeframe: "5m", timestamp: t0 - (count - i) * 5.minutes,
       open: 100.0, high: 100.5, low: 99.5, close: 100.0, volume: 10,
       created_at: Time.current, updated_at: Time.current}
    end)
  end

  # Stub WalkForward so each candidate's out-of-sample aggregate is a pure
  # function of its tp_target — lets specs assert selection logic exactly.
  def stub_walk_forward(aggregates_by_tp)
    calls = []
    allow(Backtest::WalkForward).to receive(:new) do |**opts|
      tp = opts.fetch(:strategy).instance_variable_get(:@config)[:tp_target]
      calls << {symbol: opts[:symbol], tp: tp}
      agg = {trade_count: 5, total_pnl: 0.0, worst_window_drawdown: 0.0}.merge(aggregates_by_tp.fetch(tp))
      instance_double(Backtest::WalkForward, run: {windows: [], aggregate: agg})
    end
    calls
  end

  it "evaluates MultiTimeframeSignal candidates out-of-sample and persists+activates the best per symbol" do
    insert_step_candles("BTC-USD")
    calls = stub_walk_forward(
      0.004 => {total_pnl: 10.0},
      0.006 => {total_pnl: 100.0},
      0.008 => {total_pnl: 20.0}
    )

    described_class.new.perform(symbols: ["BTC-USD"])

    expect(calls.map { |c| c[:symbol] }.uniq).to eq(["BTC-USD"])
    expect(calls.size).to eq(9) # default 3 tp x 3 sl grid

    profile = TradingProfile.active_profile("BTC-USD")
    expect(profile).to be_present
    expect(profile.tp_target.to_f).to eq(0.006)
    expect(profile.calibrated_at).to be_present
    expect(profile.metrics["objective"]).to eq("drawdown_penalized")
    expect(profile.metrics["aggregate"]["total_pnl"]).to eq(100.0)
    expect(TradingProfile.effective(symbol: "BTC-USD")).to eq(profile)
  end

  it "versions per symbol: recalibration activates a new record and keeps history" do
    insert_step_candles("BTC-USD")
    stub_walk_forward(0.004 => {total_pnl: 1.0}, 0.006 => {total_pnl: 2.0}, 0.008 => {total_pnl: 3.0})

    described_class.new.perform(symbols: ["BTC-USD"])
    first = TradingProfile.active_profile("BTC-USD")
    travel 1.hour
    described_class.new.perform(symbols: ["BTC-USD"])

    profiles = TradingProfile.where(symbol: "BTC-USD")
    expect(profiles.count).to eq(2)
    expect(first.reload.active).to be false
    expect(TradingProfile.active_profile("BTC-USD")).not_to eq(first)
  end

  it "isolates symbols: calibrating one symbol leaves another symbol's profile active" do
    insert_step_candles("BTC-USD")
    insert_step_candles("ETH-USD")
    stub_walk_forward(0.004 => {total_pnl: 1.0}, 0.006 => {total_pnl: 2.0}, 0.008 => {total_pnl: 3.0})

    described_class.new.perform(symbols: ["ETH-USD"])
    eth = TradingProfile.active_profile("ETH-USD")
    described_class.new.perform(symbols: ["BTC-USD"])

    expect(eth.reload.active).to be true
    expect(TradingProfile.active_profile("BTC-USD")).to be_present
  end

  it "accepts configurable grids instead of the hardcoded 3x3" do
    insert_step_candles("BTC-USD")
    calls = stub_walk_forward(0.01 => {total_pnl: 5.0})

    described_class.new.perform(symbols: ["BTC-USD"], tp_targets: [0.01], sl_targets: [0.005])

    expect(calls.size).to eq(1)
    expect(TradingProfile.active_profile("BTC-USD").tp_target.to_f).to eq(0.01)
  end

  it "supports a plain total_pnl objective while defaulting to drawdown-penalized" do
    insert_step_candles("BTC-USD")
    # 0.004: high pnl, huge drawdown. 0.006: lower pnl, tiny drawdown.
    stub = {
      0.004 => {total_pnl: 100.0, worst_window_drawdown: 0.5},
      0.006 => {total_pnl: 80.0, worst_window_drawdown: 0.05},
      0.008 => {total_pnl: 1.0}
    }

    stub_walk_forward(stub)
    described_class.new.perform(symbols: ["BTC-USD"])
    expect(TradingProfile.active_profile("BTC-USD").tp_target.to_f).to eq(0.006) # 76 > 50

    travel 1.hour
    stub_walk_forward(stub)
    described_class.new.perform(symbols: ["BTC-USD"], objective: :total_pnl)
    expect(TradingProfile.active_profile("BTC-USD").tp_target.to_f).to eq(0.004)
  end

  it "skips symbols without enough step candles" do
    calls = stub_walk_forward({})

    described_class.new.perform(symbols: ["NO-DATA-USD"])

    expect(calls).to be_empty
    expect(TradingProfile.where(symbol: "NO-DATA-USD")).to be_empty
  end

  it "does not persist a profile when the best candidate produced no trades" do
    insert_step_candles("BTC-USD")
    stub_walk_forward(
      0.004 => {trade_count: 0}, 0.006 => {trade_count: 0}, 0.008 => {trade_count: 0}
    )

    described_class.new.perform(symbols: ["BTC-USD"])

    expect(TradingProfile.where(symbol: "BTC-USD")).to be_empty
  end
end
