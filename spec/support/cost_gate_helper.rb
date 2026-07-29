# frozen_string_literal: true

# ADR 0006 decision 3 refuses any symbol without a passing walk-forward verdict,
# so a spec that expects an order to be placed must first establish that the
# symbol has evidence — exactly as production does.
#
# Deliberately explicit rather than a global before-hook: "this symbol has
# cleared its cost gate" is a precondition of the scenario, and a spec that
# opens a position without saying so is asserting something that cannot happen
# on the live path.
module CostGateHelper
  # `trades` defaults comfortably above RapidSignalEvaluationJob.cost_gate_min_trades
  # so the sample-size floor is not what a caller is accidentally testing. Specs
  # about the floor itself pass an explicit small number.
  def pass_cost_gate!(symbol, trades: 500)
    BacktestRun.create!(
      symbol: symbol,
      kind: "walk_forward",
      step: "5m",
      status: "succeeded",
      from_time: 30.days.ago,
      to_time: Time.current,
      metrics: {"cost_gate_passed" => true, "trade_count" => trades}
    )
  end
end

RSpec.configure { |config| config.include CostGateHelper }
