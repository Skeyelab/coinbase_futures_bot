# frozen_string_literal: true

class CreateOrders < ActiveRecord::Migration[8.0]
  def change
    create_table :orders do |t|
      t.references :position, null: true, foreign_key: true
      t.string :coinbase_order_id
      t.string :contract_id, null: false
      t.string :side, null: false
      t.string :order_type, null: false, default: "market"
      t.decimal :target_price, precision: 20, scale: 8
      t.decimal :fill_price, precision: 20, scale: 8
      t.decimal :quantity, null: false, precision: 20, scale: 8
      t.string :status, null: false, default: "pending"
      t.datetime :placed_at
      t.datetime :filled_at

      t.timestamps
    end

    add_index :orders, :coinbase_order_id, unique: true, where: "coinbase_order_id IS NOT NULL"
    add_index :orders, :status
    add_index :orders, :contract_id
  end
end
