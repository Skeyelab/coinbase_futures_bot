class CreateChatMessages < ActiveRecord::Migration[8.0]
  def change
    create_table :chat_messages do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.text :content, null: false
      t.string :message_type, null: false
      t.datetime :timestamp, null: false
      t.string :profit_impact, default: "unknown", null: false
      t.decimal :relevance_score, precision: 5, scale: 3, default: 1.0
      t.json :metadata, default: {}

      t.timestamps
    end

    add_index :chat_messages, [:chat_session_id, :timestamp]
    add_index :chat_messages, :message_type
    add_index :chat_messages, :profit_impact
    add_index :chat_messages, :relevance_score
  end
end
