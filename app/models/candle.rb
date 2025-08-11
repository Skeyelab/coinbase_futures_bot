# frozen_string_literal: true

class Candle < ApplicationRecord
  validates :symbol, :timestamp, presence: true
  validates :timeframe, inclusion: { in: %w[1h] }
  validates :timestamp, uniqueness: { scope: [ :symbol, :timeframe ] }

  scope :for_symbol, ->(sym) { where(symbol: sym) }
  scope :hourly, -> { where(timeframe: "1h") }
end