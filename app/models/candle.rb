# frozen_string_literal: true

class Candle < ApplicationRecord
  validates :symbol, :timestamp, presence: true
  validates :timeframe, inclusion: { in: %w[15m 1h 6h 1d] }
  validates :timestamp, uniqueness: { scope: [ :symbol, :timeframe ] }

  scope :for_symbol, ->(sym) { where(symbol: sym) }
  scope :hourly, -> { where(timeframe: "1h") }
  scope :fifteen_minute, -> { where(timeframe: "15m") }
end
