# frozen_string_literal: true

# Measured per-contract commissions, per product (issue #462).
#
# #458 seeded ONE dated constant — $0.85/contract, measured from oil fills — and
# CostModel applied it to every dated contract. That was right for oil and a
# guess for everything else: a dated BTC nano is a different product on a
# different fee schedule, and #459 propagated that guess into the live gates.
#
# This is the funding_rates pattern (issue #391): observations Coinbase will not
# serve retroactively, so they accrue from real fills. Commission per contract is
# stored because it needs no contract multiplier and is therefore EXACT; the
# effective rate depends on a resolver that is unreliable for some dated
# contracts, so it is recorded for observability, not for pricing.
class CreateProductFees < ActiveRecord::Migration[8.1]
  def change
    create_table :product_fees do |t|
      t.string :product_id, null: false
      t.string :liquidity, null: false, default: "TAKER" # TAKER | MAKER
      t.decimal :commission_per_contract, precision: 20, scale: 8, null: false
      t.decimal :effective_rate, precision: 12, scale: 8
      t.integer :sample_size, null: false, default: 0
      t.datetime :measured_at, null: false

      t.timestamps
    end

    add_index :product_fees, [:product_id, :liquidity], unique: true
  end
end
