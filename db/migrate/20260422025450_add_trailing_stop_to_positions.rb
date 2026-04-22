# frozen_string_literal: true

class AddTrailingStopToPositions < ActiveRecord::Migration[8.0]
  def change
    add_column :positions, :trailing_stop_enabled, :boolean, null: false, default: false
    add_column :positions, :trailing_stop_state, :jsonb, null: false, default: {}
    add_index :positions, :trailing_stop_enabled, name: "index_positions_on_trailing_stop_enabled"
  end
end
