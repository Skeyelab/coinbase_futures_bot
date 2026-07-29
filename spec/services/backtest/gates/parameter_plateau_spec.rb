# frozen_string_literal: true

require "rails_helper"

# Gate 6 of the #376 go-live framework (issue #541): the chosen tp/sl
# configuration must sit on a PLATEAU in parameter space — neighbours at
# 50–150% of the baseline stop and 80–120% of the baseline target must stay
# net-positive. A lone spike whose neighbours lose money is the signature of a
# curve fit that time-slicing (gate 4) does not catch.
RSpec.describe Backtest::Gates::ParameterPlateau, type: :service do
  def cell(stop_scale, target_scale, net_pnl, trade_count: 10)
    {stop_scale: stop_scale, target_scale: target_scale, net_pnl: net_pnl, trade_count: trade_count}
  end

  describe ".evaluate" do
    it "accepts a ridge: every neighbour net-positive, even when weaker than the baseline" do
      cells = described_class::STOP_SCALES.product(described_class::TARGET_SCALES).map do |ss, ts|
        # Baseline is best; neighbours decay but stay positive — a plateau,
        # not a peak. The gate asks "not off a cliff", not "matches".
        distance = (ss - 1.0).abs + (ts - 1.0).abs
        cell(ss, ts, 500.0 - 400.0 * distance)
      end

      verdict = described_class.evaluate(cells: cells)

      expect(verdict[:passed]).to be(true)
      expect(verdict[:gate]).to eq("parameter_plateau")
      expect(verdict[:cell_count]).to eq(25)
      expect(verdict[:failing_cells]).to be_empty
      expect(verdict[:baseline][:net_pnl]).to eq(500.0)
    end

    it "rejects an isolated spike: a profitable baseline whose neighbours lose money" do
      cells = described_class::STOP_SCALES.product(described_class::TARGET_SCALES).map do |ss, ts|
        baseline = (ss - 1.0).abs < 1e-9 && (ts - 1.0).abs < 1e-9
        cell(ss, ts, baseline ? 900.0 : -50.0)
      end

      verdict = described_class.evaluate(cells: cells)

      expect(verdict[:passed]).to be(false)
      expect(verdict[:failing_cells].size).to eq(24)
      expect(verdict[:baseline][:passed]).to be(true)
    end

    it "cannot be satisfied by a config that fails the cost gate itself (additive, not alternative)" do
      # Every neighbour profitable but the BASELINE is not: the gate must not
      # pass a losing candidate just because its surroundings look healthy.
      cells = described_class::STOP_SCALES.product(described_class::TARGET_SCALES).map do |ss, ts|
        baseline = (ss - 1.0).abs < 1e-9 && (ts - 1.0).abs < 1e-9
        cell(ss, ts, baseline ? -10.0 : 100.0)
      end

      verdict = described_class.evaluate(cells: cells)

      expect(verdict[:passed]).to be(false)
      expect(verdict[:failing_cells]).to contain_exactly(
        a_hash_including(stop_scale: 1.0, target_scale: 1.0)
      )
    end

    it "treats a zero-trade neighbour as failing: silence is not evidence of a plateau" do
      cells = [
        cell(1.0, 1.0, 500.0),
        cell(0.75, 1.0, 0.0, trade_count: 0)
      ]

      verdict = described_class.evaluate(cells: cells)

      expect(verdict[:passed]).to be(false)
      expect(verdict[:failing_cells]).to contain_exactly(
        a_hash_including(stop_scale: 0.75, trade_count: 0)
      )
    end

    it "requires the baseline (1.0/1.0) cell — a grid without the candidate judges nothing" do
      expect {
        described_class.evaluate(cells: [cell(0.5, 0.8, 100.0)])
      }.to raise_error(ArgumentError, /baseline/)
    end
  end

  describe ".run" do
    it "sweeps the scale grid through the walk-forward harness with scaled tp/sl and judges the aggregate" do
      profile = TradingProfile.effective
      seen_configs = []

      fake_strategy = instance_double(Strategy::MultiTimeframeSignal)
      allow(Trading::StrategyFactory).to receive(:multi_timeframe) do |**opts|
        seen_configs << opts.slice(:tp_target, :sl_target)
        fake_strategy
      end

      fake_walk_forward = instance_double(Backtest::WalkForward)
      allow(Backtest::WalkForward).to receive(:new).and_return(fake_walk_forward)
      allow(fake_walk_forward).to receive(:run).and_return(
        {windows: [], aggregate: {total_pnl: 42.0, trade_count: 7}}
      )

      verdict = described_class.run(symbol: "BTC-PERP-INTX",
        from: Time.parse("2026-01-01T00:00:00Z"), to: Time.parse("2026-03-01T00:00:00Z"),
        train_span: 14.days, eval_span: 7.days)

      # Full 5x5 cross of the issue-specified scales, each through its own
      # walk-forward run with tp/sl scaled off the effective profile baseline.
      expect(seen_configs.size).to eq(25)
      expect(seen_configs).to include(
        {tp_target: profile.tp_target.to_f * 0.8, sl_target: profile.sl_target.to_f * 0.5},
        {tp_target: profile.tp_target.to_f, sl_target: profile.sl_target.to_f},
        {tp_target: profile.tp_target.to_f * 1.2, sl_target: profile.sl_target.to_f * 1.5}
      )
      expect(verdict[:passed]).to be(true)
      expect(verdict[:cell_count]).to eq(25)
      expect(verdict[:baseline_tp_target]).to eq(profile.tp_target.to_f)
      expect(verdict[:baseline_sl_target]).to eq(profile.sl_target.to_f)
    end
  end
end
