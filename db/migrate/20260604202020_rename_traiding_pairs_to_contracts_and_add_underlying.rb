class RenameTraidingPairsToContractsAndAddUnderlying < ActiveRecord::Migration[8.1]
  def change
    rename_table :trading_pairs, :contracts
    add_reference :contracts, :underlying, foreign_key: true
  end
end
