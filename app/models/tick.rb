# frozen_string_literal: true

class Tick < ApplicationRecord
  validates :product_id, presence: true
  validates :observed_at, presence: true
  validates :price, presence: true, numericality: true

  scope :for_product, ->(pid) { where(product_id: pid) }
  scope :between, ->(start_time, end_time) { where(observed_at: start_time..end_time) }
end


