class AddExpirationFieldsToTradingPairs < ActiveRecord::Migration[8.0]
  def change
    add_column :trading_pairs, :contract_type, :string
    add_column :trading_pairs, :expiration_date, :date
    add_column :trading_pairs, :is_perpetual, :boolean, default: false

    # Add indexes for querying by expiration date
    add_index :trading_pairs, :expiration_date
    add_index :trading_pairs, [ :is_perpetual, :expiration_date ]
  end
end
