class CreateChatSessions < ActiveRecord::Migration[8.0]
  def change
    create_table :chat_sessions do |t|
      t.string :session_id, null: false
      t.string :name
      t.boolean :active, default: true, null: false
      t.json :metadata, default: {}

      t.timestamps
    end

    add_index :chat_sessions, :session_id, unique: true
    add_index :chat_sessions, :active
    add_index :chat_sessions, :updated_at
  end
end
