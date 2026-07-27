# frozen_string_literal: true

# A run must be self-describing (issue #471). Storing only fee_rate collapsed
# the venue's fee SHAPE to a scalar, which cannot express the per-contract
# dollar floor — so a stored run could not be re-costed faithfully, and the
# re-costing surface in #408/#409 would have been built on a lossy column.
class AddPerContractFeeToBacktestRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :backtest_runs, :per_contract_fee, :decimal, precision: 12, scale: 6
  end
end
