# frozen_string_literal: true

class Candle < ApplicationRecord
  validates :symbol, :timestamp, presence: true
  validates :timeframe, inclusion: { in: %w[1m 5m 15m 1h 6h 1d] }
  validates :timestamp, uniqueness: { scope: [ :symbol, :timeframe ] }

  scope :for_symbol, ->(sym) { where(symbol: sym) }
  scope :one_minute, -> { where(timeframe: "1m") }
  scope :five_minute, -> { where(timeframe: "5m") }
  scope :fifteen_minute, -> { where(timeframe: "15m") }
  scope :hourly, -> { where(timeframe: "1h") }
end
