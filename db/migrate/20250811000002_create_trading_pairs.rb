# frozen_string_literal: true

class CreateTradingPairs < ActiveRecord::Migration[7.2]
  def change
    create_table :trading_pairs do |t|
      t.string :product_id, null: false # e.g., BTC-USD
      t.string :base_currency
      t.string :quote_currency
      t.string :status
      t.decimal :min_size, precision: 20, scale: 10
      t.decimal :price_increment, precision: 20, scale: 10
      t.decimal :size_increment, precision: 20, scale: 10
      t.boolean :enabled, null: false, default: true
      t.timestamps
    end
    add_index :trading_pairs, :product_id, unique: true
  end
end
