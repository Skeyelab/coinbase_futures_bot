# frozen_string_literal: true

class CreateTradingProfiles < ActiveRecord::Migration[8.1]
  def up
    # Drop the old table if it exists with the legacy column schema
    # (created by a branch that was never merged to main).
    if table_exists?(:trading_profiles)
      drop_table :trading_profiles
    end

    create_table :trading_profiles do |t|
      t.string :name, null: false
      t.text :description

      # Risk / sizing
      t.decimal :tp_target, precision: 10, scale: 6, null: false, default: "0.006"
      t.decimal :sl_target, precision: 10, scale: 6, null: false, default: "0.004"
      t.decimal :risk_fraction, precision: 10, scale: 6, null: false, default: "0.02"
      t.integer :max_position_size, null: false, default: 15
      t.integer :min_position_size, null: false, default: 5

      # Signal filtering
      t.decimal :min_confidence_threshold, precision: 6, scale: 2, null: false, default: "60.0"
      t.integer :max_signals_per_hour, null: false, default: 10
      t.integer :deduplication_window, null: false, default: 300

      # Active flag — exactly one profile active at a time
      t.boolean :active, null: false, default: false

      t.timestamps
    end

    add_index :trading_profiles, :name, unique: true
    add_index :trading_profiles, :active
  end

  def down
    drop_table :trading_profiles
  end
end
