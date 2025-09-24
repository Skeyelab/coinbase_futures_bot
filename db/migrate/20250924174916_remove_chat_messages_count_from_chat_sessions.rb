class RemoveChatMessagesCountFromChatSessions < ActiveRecord::Migration[8.0]
  def change
    remove_index :chat_sessions, :chat_messages_count, if_exists: true
    remove_column :chat_sessions, :chat_messages_count, :integer, if_exists: true
  end
end
