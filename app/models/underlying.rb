# frozen_string_literal: true

class Underlying < ApplicationRecord
  ASSET_CLASSES = %w[crypto commodity].freeze

  validates :symbol, presence: true, uniqueness: true
  validates :asset_class, presence: true, inclusion: {in: ASSET_CLASSES}

  has_many :contracts, dependent: :nullify

  scope :crypto, -> { where(asset_class: "crypto") }
  scope :commodity, -> { where(asset_class: "commodity") }
end
