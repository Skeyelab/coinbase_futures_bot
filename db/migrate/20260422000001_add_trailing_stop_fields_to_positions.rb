# frozen_string_literal: true

class AddTrailingStopFieldsToPositions < ActiveRecord::Migration[8.0]
  def change
    add_column :positions, :trailing_stop_enabled, :boolean, default: false, null: false
    add_column :positions, :trailing_stop_state, :jsonb, default: {}, null: false

    add_index :positions, :trailing_stop_enabled
  end
end
