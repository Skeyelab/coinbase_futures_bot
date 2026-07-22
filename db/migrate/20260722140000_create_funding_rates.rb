# frozen_string_literal: true

# Perp funding history is NOT reconstructible (issue #391): candle backfills
# carry zero funding data and the products API only ever exposes the *next*
# funding timestamp. Every hour that passes without a snapshot is a permanently
# missing observation, so this table exists to start accruing immediately —
# ahead of the CostModel/simulator/gate modeling that will consume it.
class CreateFundingRates < ActiveRecord::Migration[8.1]
  def change
    create_table :funding_rates do |t|
      t.string :product_id, null: false
      # The timestamp the rate applies at, not when we observed it. One row per
      # (product, funding timestamp); re-observations upsert, so the stored rate
      # converges on the value actually applied at settlement.
      t.datetime :funding_time, null: false
      # Signed per-interval fraction (longs pay positive, shorts collect).
      # 0.000021 = 2.1 bps/hour on BIP; scale 12 keeps sub-0.01bps resolution.
      t.decimal :funding_rate, precision: 20, scale: 12, null: false
      t.integer :funding_interval_seconds, null: false
      t.decimal :open_interest, precision: 30, scale: 10
      t.datetime :observed_at, null: false

      t.timestamps
    end

    add_index :funding_rates, [:product_id, :funding_time], unique: true
  end
end
