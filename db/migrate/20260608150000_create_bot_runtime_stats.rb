# frozen_string_literal: true

class CreateBotRuntimeStats < ActiveRecord::Migration[8.1]
  def change
    create_table :bot_runtime_stats do |t|
      t.string :key, null: false
      t.datetime :recorded_at, null: false

      t.timestamps
    end

    add_index :bot_runtime_stats, :key, unique: true
  end
end
