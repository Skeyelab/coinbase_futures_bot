# frozen_string_literal: true

class SentimentAggregate < ApplicationRecord
  validates :symbol, :window, :window_end_at, presence: true
  validates :symbol, uniqueness: { scope: [ :window, :window_end_at ] }

  scope :for_symbol, ->(sym) { where(symbol: sym) }
  scope :for_window, ->(win) { where(window: win) }
end