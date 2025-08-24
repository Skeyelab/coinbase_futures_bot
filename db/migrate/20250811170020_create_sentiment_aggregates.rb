class CreateSentimentAggregates < ActiveRecord::Migration[8.0]
  def change
    create_table :sentiment_aggregates do |t|
      t.string :symbol, null: false
      t.string :window, null: false # e.g., "15m", "1h"
      t.datetime :window_end_at, null: false

      t.integer :count, null: false, default: 0
      t.decimal :avg_score, precision: 8, scale: 4, null: false, default: 0
      t.decimal :weighted_score, precision: 8, scale: 4, null: false, default: 0
      t.decimal :z_score, precision: 8, scale: 4, null: false, default: 0

      t.jsonb :meta, null: false, default: {}

      t.timestamps
    end

    add_index :sentiment_aggregates, [:symbol, :window, :window_end_at], unique: true, name: "index_sentiment_aggregates_on_sym_win_end"
    add_index :sentiment_aggregates, :window_end_at
    add_index :sentiment_aggregates, :symbol
  end
end
