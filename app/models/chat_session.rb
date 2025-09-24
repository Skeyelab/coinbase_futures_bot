# frozen_string_literal: true

class ChatSession < ApplicationRecord
  has_many :chat_messages, dependent: :destroy

  validates :session_id, presence: true, uniqueness: true
  validates :active, inclusion: {in: [true, false]}

  scope :recent, -> { order(updated_at: :desc) }
  scope :active, -> { where(active: true) }
  scope :profitable, -> { joins(:chat_messages).where(chat_messages: {profit_impact: %w[medium high]}).distinct }

  def self.find_or_create_by_session_id(session_id)
    find_or_create_by(session_id: session_id)
  end

  def message_count
    chat_messages.count
  end

  def last_activity
    chat_messages.maximum(:timestamp) || updated_at
  end

  def profitable_messages
    chat_messages.profitable
  end

  def deactivate!
    update!(active: false)
  end
end
