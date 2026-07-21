class AddFeeColumnsToPositions < ActiveRecord::Migration[8.1]
  def change
    add_column :positions, :entry_fee, :decimal
    add_column :positions, :exit_fee, :decimal
  end
end
