# frozen_string_literal: true

# Path-dependent (highlow2) outcome labels for every bar (issue #302 step 1).
# Keyed by the full shape so multiple tp/sl/horizon configurations coexist and
# a training read is one indexed query.
class CreatePathDependentLabels < ActiveRecord::Migration[8.1]
  def change
    create_table :path_dependent_labels do |t|
      t.string :symbol, null: false
      t.string :timeframe, null: false, default: "5m"
      t.datetime :bar_timestamp, null: false
      t.decimal :tp_frac, precision: 10, scale: 6, null: false
      t.decimal :sl_frac, precision: 10, scale: 6, null: false
      t.integer :horizon, null: false
      t.string :direction, null: false
      t.string :label, null: false
      # Bars from entry to resolution (win/loss); nil while unresolved.
      t.integer :resolved_at_bars
      t.timestamps

      t.index %i[symbol timeframe bar_timestamp tp_frac sl_frac horizon direction],
        unique: true, name: "idx_path_dependent_labels_shape_key"
      t.index %i[symbol label], name: "idx_path_dependent_labels_on_symbol_and_label"
    end
  end
end
