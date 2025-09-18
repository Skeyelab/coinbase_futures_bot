# frozen_string_literal: true

class ChatMessage < ApplicationRecord
  belongs_to :chat_session

  validates :content, presence: true
  validates :message_type, presence: true, inclusion: {in: %w[user bot system]}
  validates :timestamp, presence: true
  validates :profit_impact, inclusion: {in: %w[unknown low medium high]}
  validates :relevance_score, presence: true, numericality: {greater_than: 0, less_than_or_equal_to: 5}

  enum :profit_impact, {unknown: "unknown", low: "low", medium: "medium", high: "high"}
  enum :message_type, {user: "user", bot: "bot", system: "system"}

  scope :recent, -> { order(timestamp: :desc) }
  scope :profitable, -> { where(profit_impact: [:medium, :high]) }
  scope :user_messages, -> { where(message_type: "user") }
  scope :bot_responses, -> { where(message_type: "bot") }
  scope :by_relevance, -> { order(relevance_score: :desc) }

  before_validation :set_timestamp, if: -> { timestamp.blank? }

  def self.for_ai_context(max_tokens = 4000)
    # Simple token estimation: ~4 characters per token
    max_messages = [max_tokens / 50, 50].min # Conservative estimate

    profitable.recent.limit(max_messages)
  end

  def trading_related?
    profit_impact.in?(%w[medium high]) ||
      content.match?(/position|signal|trade|profit|loss|entry|exit|market/i)
  end

  private

  def set_timestamp
    self.timestamp = Time.current
  end
end
