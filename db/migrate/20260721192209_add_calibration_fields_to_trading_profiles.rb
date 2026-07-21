class AddCalibrationFieldsToTradingProfiles < ActiveRecord::Migration[8.1]
  def change
    add_column :trading_profiles, :symbol, :string
    add_column :trading_profiles, :metrics, :jsonb, default: {}, null: false
    add_column :trading_profiles, :calibrated_at, :datetime

    # One active profile PER SYMBOL (NULL symbol = the global profile) instead
    # of one active profile total, so calibration can activate per-symbol
    # params without fighting the global default (issue #299).
    # nulls_not_distinct keeps "at most one active global profile" enforced.
    remove_index :trading_profiles, name: "index_trading_profiles_one_active"
    add_index :trading_profiles, :symbol,
      name: "index_trading_profiles_one_active_per_symbol",
      unique: true, where: "(active IS TRUE)", nulls_not_distinct: true
    add_index :trading_profiles, :symbol
  end
end
