# frozen_string_literal: true

# Backtests were write-only (issue #406, PRD #405): the rake task built a
# Backtest::Result, printed it, and dropped it. Nothing could answer "did this
# change help?" without re-running both sides in two terminals.
#
# A row captures both the INPUTS (so a run is reproducible) and the OUTPUTS (so
# runs are comparable). The inputs matter as much as the metrics here: ADR 0002
# moved the venue, so a stored run is only interpretable alongside the fee and
# sizing assumptions it actually ran under.
class CreateBacktestRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :backtest_runs do |t|
      t.string :symbol, null: false
      t.string :kind, null: false          # single | walk_forward
      t.string :step, null: false          # 1m | 5m | 15m | 1h, mirrors Engine::STEP_SCOPES
      t.datetime :from_time, null: false
      t.datetime :to_time, null: false

      t.decimal :starting_equity, precision: 20, scale: 8
      # The RESOLVED rate, never nil. The engine falls back to CostModel when
      # passed nil, so storing nil would make a historical run re-interpret
      # itself under whatever the env var says later — silently destroying
      # comparability across the ADR 0002 venue change.
      t.decimal :fee_rate, precision: 12, scale: 8
      t.decimal :slippage, precision: 12, scale: 8
      t.decimal :contract_size_usd, precision: 20, scale: 8

      t.integer :train_days                # walk-forward only
      t.integer :eval_days

      t.string :status, null: false, default: "pending"  # pending|running|succeeded|failed

      # Result#to_h minus the trade list. Kept whole rather than split into
      # columns so a new metric does not require a migration.
      t.jsonb :metrics
      # One entry per step: a 30-day 5m window is ~8,600 entries, 1m ~43,000.
      # Fine as jsonb, but index views must not select it.
      t.jsonb :equity_curve
      t.jsonb :trades
      t.jsonb :windows                     # walk-forward per-window report incl. data_coverage

      t.text :error_message
      t.datetime :started_at
      t.datetime :finished_at

      t.timestamps
    end

    add_index :backtest_runs, [:symbol, :created_at]
    add_index :backtest_runs, :status
  end
end
