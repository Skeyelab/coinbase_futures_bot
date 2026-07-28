# frozen_string_literal: true

# Links a partially-closed slice back to the position it was cut from.
#
# Since #509 a partial reduce creates its own CLOSED row so that LossLimits and
# StoplossGuard can see the realized dollars. Nothing recorded that the row was
# a slice rather than a trade, so every consumer that counts CLOSED rows counted
# one position reduced six times as six trades. SymbolCircuitBreakerJob's
# MIN_TRADES=5 sample gate was the first to be wrong because of it: it could
# suspend a symbol on the evidence of a single position.
#
# Nullable and unvalidated by design — every pre-existing CLOSED row is a whole
# trade, which is exactly what a NULL parent means.
class AddParentPositionIdToPositions < ActiveRecord::Migration[8.1]
  def change
    add_column :positions, :parent_position_id, :bigint
    add_index :positions, :parent_position_id
  end
end
