# frozen_string_literal: true

class CreateCandles < ActiveRecord::Migration[7.2]
  def change
    create_table :candles do |t|
      t.string :symbol, null: false
      t.string :timeframe, null: false, default: "1h"
      t.datetime :timestamp, null: false
      t.decimal :open, precision: 20, scale: 10, null: false
      t.decimal :high, precision: 20, scale: 10, null: false
      t.decimal :low, precision: 20, scale: 10, null: false
      t.decimal :close, precision: 20, scale: 10, null: false
      t.decimal :volume, precision: 30, scale: 10, null: false, default: 0
      t.timestamps
    end

    add_index :candles, [ :symbol, :timeframe, :timestamp ], unique: true
  end
end