# frozen_string_literal: true

require "rails_helper"

# Gate 7 of the #376 go-live framework (issue #541): net expectancy must stay
# positive with modeled costs stressed to 1.5x and 2x, and the gate must
# report the BREAK-EVEN cost multiple — the margin matters more than the
# pass/fail. Motivated by #531 (a 100x fee-modeling error read as a venue
# finding) and #486 (the ~3 bps perp taker rate has never met a real fill).
RSpec.describe Backtest::Gates::PessimisticCost, type: :service do
  describe ".evaluate" do
    it "rejects a strategy that only survives at seed costs" do
      # Net +100 on 300 of modeled costs: at 1.5x the extra 150 of cost
      # wipes the edge. This is exactly the config gate 1 (reconciliation)
      # would wave through.
      verdict = described_class.evaluate(total_pnl: 100.0, stressable_costs: 300.0, trade_count: 10)

      expect(verdict[:passed]).to be(false)
      expect(verdict[:gate]).to eq("pessimistic_cost")
      stressed = verdict[:multiples].index_by { |m| m[:multiple] }
      expect(stressed[1.5][:net_pnl]).to eq(-50.0)
      expect(stressed[1.5][:passed]).to be(false)
      expect(stressed[2.0][:net_pnl]).to eq(-200.0)
      # Break-even multiple: 1 + 100/300 — the edge dies at ~1.33x costs.
      expect(verdict[:break_even_cost_multiple]).to be_within(0.001).of(1.333)
    end

    it "accepts a strategy whose edge survives 2x costs, and still reports the margin" do
      verdict = described_class.evaluate(total_pnl: 1000.0, stressable_costs: 300.0, trade_count: 10)

      expect(verdict[:passed]).to be(true)
      stressed = verdict[:multiples].index_by { |m| m[:multiple] }
      expect(stressed[1.5][:net_pnl]).to eq(850.0)
      expect(stressed[2.0][:net_pnl]).to eq(700.0)
      expect(stressed[2.0][:expectancy]).to eq(70.0)
      expect(verdict[:break_even_cost_multiple]).to be_within(0.001).of(4.333)
    end

    it "reports a break-even multiple below 1 for a seed-negative strategy (fails, additive with gate 1)" do
      verdict = described_class.evaluate(total_pnl: -60.0, stressable_costs: 300.0, trade_count: 10)

      expect(verdict[:passed]).to be(false)
      expect(verdict[:break_even_cost_multiple]).to be_within(0.001).of(0.8)
    end

    it "fails a zero-trade sample: no trades is no evidence" do
      verdict = described_class.evaluate(total_pnl: 0.0, stressable_costs: 0.0, trade_count: 0)

      expect(verdict[:passed]).to be(false)
      expect(verdict[:break_even_cost_multiple]).to be_nil
    end

    it "reports an infinite break-even multiple when profitable with zero modeled costs" do
      verdict = described_class.evaluate(total_pnl: 100.0, stressable_costs: 0.0, trade_count: 5)

      expect(verdict[:passed]).to be(true)
      expect(verdict[:break_even_cost_multiple]).to eq(Float::INFINITY)
    end
  end

  describe ".from_result" do
    def trade(pnl:, fees:, funding: 0.0, entry_price: 100.0, exit_price: 101.0, quantity: 1.0)
      {pnl: pnl, fees: fees, funding: funding,
       entry_price: entry_price, exit_price: exit_price, quantity: quantity}
    end

    it "stresses fees + funding recorded on the trades" do
      result = Backtest::Result.new(
        trades: [trade(pnl: 50.0, fees: 10.0, funding: 5.0), trade(pnl: 30.0, fees: 10.0, funding: 5.0)],
        equity_curve: [10_000.0], starting_equity: 10_000.0, from: nil, to: nil
      )

      verdict = described_class.from_result(result)

      # pnl 80 over 30 stressable: dies at 1 + 80/30 ≈ 3.67x — passes both rungs.
      expect(verdict[:passed]).to be(true)
      expect(verdict[:seed][:stressable_costs]).to eq(30.0)
      expect(verdict[:break_even_cost_multiple]).to be_within(0.001).of(3.667)
    end

    it "folds in an estimated slippage cost when given the modeled slippage rate" do
      # Slippage lives inside the fill prices, not on the trade record, so it
      # is reconstructed: rate x (entry notional + exit notional).
      result = Backtest::Result.new(
        trades: [trade(pnl: 50.0, fees: 10.0, entry_price: 100.0, exit_price: 100.0, quantity: 10.0)],
        equity_curve: [10_000.0], starting_equity: 10_000.0, from: nil, to: nil
      )

      verdict = described_class.from_result(result, slippage_rate: 0.001)

      # 0.001 x (100x10 + 100x10) = 2.0 of slippage on top of 10.0 fees.
      expect(verdict[:seed][:stressable_costs]).to eq(12.0)
    end
  end

  describe ".from_walk_forward" do
    it "judges a walk-forward report by its aggregate totals" do
      report = {
        windows: [],
        aggregate: {total_pnl: 90.0, total_fees: 200.0, total_funding: 40.0, trade_count: 20}
      }

      verdict = described_class.from_walk_forward(report)

      # 90 over 240 stressable: break-even at 1.375x — fails the 1.5x rung.
      expect(verdict[:passed]).to be(false)
      expect(verdict[:seed][:stressable_costs]).to eq(240.0)
      expect(verdict[:break_even_cost_multiple]).to be_within(0.001).of(1.375)
    end
  end
end
