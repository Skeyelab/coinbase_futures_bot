# frozen_string_literal: true

class CreateTicks < ActiveRecord::Migration[7.2]
  def change
    create_table :ticks do |t|
      t.string :product_id, null: false
      t.decimal :price, null: false, precision: 15, scale: 5
      t.datetime :observed_at, null: false

      t.timestamps
    end

    add_index :ticks, [:product_id, :observed_at]
  end
end
