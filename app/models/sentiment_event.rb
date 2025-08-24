# frozen_string_literal: true

class SentimentEvent < ApplicationRecord
  validates :source, :published_at, :raw_text_hash, presence: true
  validates :raw_text_hash, uniqueness: {scope: :source}

  scope :for_symbol, ->(sym) { where(symbol: sym) }
  scope :recent, ->(since_time) { where("published_at >= ?", since_time) }
  scope :unscored, -> { where(score: nil) }
end
