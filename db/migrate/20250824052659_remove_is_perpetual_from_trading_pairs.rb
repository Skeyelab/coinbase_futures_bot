class RemoveIsPerpetualFromTradingPairs < ActiveRecord::Migration[8.0]
  def change
    remove_column :trading_pairs, :is_perpetual, :boolean
  end
end
