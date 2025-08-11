# frozen_string_literal: true

class TradingPair < ApplicationRecord
  validates :product_id, presence: true, uniqueness: true
  scope :enabled, -> { where(enabled: true) }
end