# frozen_string_literal: true

class CreateTradingProfiles < ActiveRecord::Migration[8.0]
  def change
    create_table :trading_profiles do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.decimal :signal_equity_usd, precision: 15, scale: 2, null: false
      t.decimal :min_confidence, precision: 5, scale: 2, null: false
      t.integer :max_signals_per_hour, null: false
      t.integer :evaluation_interval_seconds, null: false
      t.decimal :strategy_risk_fraction, precision: 8, scale: 6, null: false
      t.decimal :strategy_tp_target, precision: 8, scale: 6, null: false
      t.decimal :strategy_sl_target, precision: 8, scale: 6, null: false
      t.boolean :active, null: false, default: false

      t.timestamps
    end

    add_index :trading_profiles, :slug, unique: true
    add_index :trading_profiles, :active
  end
end
