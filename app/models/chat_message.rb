# frozen_string_literal: true

class ChatMessage < ApplicationRecord
  belongs_to :chat_session

  # Token estimation constants for AI context management
  # More sophisticated estimation based on content analysis
  BASE_TOKENS_PER_MESSAGE = 10  # Base overhead for message structure
  TOKENS_PER_CHAR = 0.25        # ~4 chars per token average
  MAX_TOKENS_PER_MESSAGE = 200  # Cap for very long messages

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
    # Calculate maximum messages based on token estimation
    max_messages = [max_tokens / 50, 50].min # Conservative estimate

    profitable.recent.limit(max_messages)
  end

  # More accurate token estimation for individual messages
  def estimated_tokens
    content_tokens = (content.length * TOKENS_PER_CHAR).to_i
    total_tokens = BASE_TOKENS_PER_MESSAGE + content_tokens
    [total_tokens, MAX_TOKENS_PER_MESSAGE].min
  end

  def trading_related?
    profit_impact.in?(%w[medium high]) ||
      content.match?(ChatMemoryService::TRADING_KEYWORDS_REGEX)
  end

  private

  def set_timestamp
    self.timestamp = Time.current
  end
end
