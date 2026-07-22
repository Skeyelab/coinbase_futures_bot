# frozen_string_literal: true

# One observation of a perpetual's funding rate for a given funding timestamp
# (issue #391). Funding is a position-TIME cost — it is charged to open
# positions at each funding timestamp crossed, never as part of fill cost.
class FundingRate < ApplicationRecord
  validates :product_id, :funding_time, :observed_at, presence: true
  validates :funding_rate, presence: true
  validates :funding_interval_seconds, numericality: {greater_than: 0}
  validates :funding_time, uniqueness: {scope: :product_id}

  scope :for_product, ->(product_id) { where(product_id: product_id) }
  scope :chronological, -> { order(:funding_time) }
end
