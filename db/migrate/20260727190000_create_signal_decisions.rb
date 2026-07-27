# frozen_string_literal: true

# Why a trade candidate was declined (issue #480).
#
# Every skip was a logger.debug that rolled off, so "3 trades in 10 days" was
# never a measurement — it was an ABSENCE of measurement. Nothing could
# distinguish "the strategy found nothing" from "one gate silently rejected
# thousands of candidates", which made the central question of the roadmap
# unanswerable and made tuning selectivity guesswork.
#
# One row per evaluation, carrying the terminal disposition and a reason code,
# plus lineage to the Position when the candidate actually traded — which #376
# gate 4 (backtest<->paper parity) needs and which did not exist before.
class CreateSignalDecisions < ActiveRecord::Migration[8.1]
  def change
    create_table :signal_decisions do |t|
      t.string :product_id, null: false     # the evaluated product (e.g. BTC-USD)
      t.string :contract_id                 # resolved contract, nil if resolution failed
      t.string :asset
      t.string :disposition, null: false    # traded | rejected
      t.string :reason, null: false         # reason code; "traded" when it went through
      t.string :side
      t.decimal :confidence, precision: 6, scale: 2
      t.decimal :quantity, precision: 20, scale: 8
      t.jsonb :context, default: {}         # small per-reason detail (caps, thresholds)
      t.bigint :position_id                 # lineage; null unless disposition = traded
      t.datetime :evaluated_at, null: false

      t.timestamps
    end

    # The two queries this table exists to serve: the rejection histogram for a
    # product over a window, and the lineage lookup from a position.
    add_index :signal_decisions, [:product_id, :evaluated_at]
    add_index :signal_decisions, [:reason, :evaluated_at]
    add_index :signal_decisions, :position_id
  end
end
