class CreateSentimentEvents < ActiveRecord::Migration[8.0]
  def change
    create_table :sentiment_events do |t|
      t.string :source, null: false
      t.string :symbol
      t.string :url
      t.string :title
      t.decimal :score, precision: 6, scale: 3
      t.decimal :confidence, precision: 6, scale: 3
      t.datetime :published_at, null: false
      t.string :raw_text_hash, null: false
      t.jsonb :meta, null: false, default: {}

      t.timestamps
    end

    add_index :sentiment_events, :published_at
    add_index :sentiment_events, :symbol
    add_index :sentiment_events, [ :source, :raw_text_hash ], unique: true, name: "index_sentiment_events_on_source_and_raw_text_hash"
    add_index :sentiment_events, :url
  end
end