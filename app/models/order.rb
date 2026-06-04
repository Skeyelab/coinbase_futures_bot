# frozen_string_literal: true

class Order < ApplicationRecord
  SIDES = %w[buy sell].freeze
  ORDER_TYPES = %w[market limit].freeze
  STATUSES = %w[pending open filled cancelled failed].freeze

  belongs_to :position, optional: true

  validates :contract_id, presence: true
  validates :side, presence: true, inclusion: {in: SIDES}
  validates :order_type, presence: true, inclusion: {in: ORDER_TYPES}
  validates :quantity, presence: true, numericality: {greater_than: 0}
  validates :status, presence: true, inclusion: {in: STATUSES}
  validates :coinbase_order_id, uniqueness: {allow_nil: true}

  scope :for_position, ->(position) { where(position: position) }
  scope :filled, -> { where(status: "filled") }
  scope :pending, -> { where(status: "pending") }
  scope :opening, -> { where(side: "buy") }
  scope :closing, -> { where(side: "sell") }

  def filled?
    status == "filled"
  end

  def pending?
    status == "pending"
  end

  def slippage
    return nil unless target_price && fill_price && target_price > 0

    fill_price - target_price
  end

  def slippage_bps
    return nil unless slippage && target_price > 0

    (slippage / target_price) * 10_000
  end
end
