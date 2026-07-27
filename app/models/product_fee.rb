# frozen_string_literal: true

# A measured per-contract commission for one product (issue #462).
#
# Ground truth for what a contract actually costs, replacing the single seeded
# dated constant that #458 measured from oil fills and CostModel then applied to
# every dated product.
class ProductFee < ApplicationRecord
  LIQUIDITIES = %w[TAKER MAKER].freeze

  validates :product_id, presence: true
  validates :liquidity, inclusion: {in: LIQUIDITIES}
  validates :commission_per_contract, numericality: {greater_than_or_equal_to: 0}
  validates :sample_size, numericality: {greater_than_or_equal_to: 0}

  scope :for_product, ->(product_id) { where(product_id: product_id.to_s) }
  scope :taker, -> { where(liquidity: "TAKER") }
  scope :maker, -> { where(liquidity: "MAKER") }

  # A single fill is an observation, not a measurement — one atypical
  # commission should not move what every gate charges. Tunable because the
  # right floor depends on how much history has accrued.
  def self.min_sample_size
    ENV.fetch("PRODUCT_FEE_MIN_SAMPLE", "3").to_i
  end

  # The measured per-contract commission for a product, or nil when nothing
  # trustworthy has been measured yet — nil means "fall back to the seeded
  # constant", never "this product is free".
  def self.measured_per_contract(product_id, liquidity: "TAKER")
    fee = for_product(product_id).where(liquidity: liquidity)
      .where(sample_size: min_sample_size..).first
    fee&.commission_per_contract&.to_f
  end
end
