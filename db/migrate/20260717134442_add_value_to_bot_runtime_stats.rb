class AddValueToBotRuntimeStats < ActiveRecord::Migration[8.1]
  def change
    add_column :bot_runtime_stats, :value, :jsonb
  end
end
