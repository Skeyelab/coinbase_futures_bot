# frozen_string_literal: true

class CreateTradingProfiles < ActiveRecord::Migration[8.1]
  def up
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

    # Case-insensitive unique index on name to match model validation semantics
    add_index :trading_profiles, "lower(name)", unique: true, name: "index_trading_profiles_on_lower_name"

    # Partial unique index — enforces at most one active profile at the DB level
    add_index :trading_profiles, :active, unique: true, where: "active IS TRUE", name: "index_trading_profiles_one_active"
  end

  def down
    drop_table :trading_profiles
  end
end
