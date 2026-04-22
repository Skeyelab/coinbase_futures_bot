# frozen_string_literal: true

class TradingProfile < ApplicationRecord
  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true
  validates :signal_equity_usd, numericality: {greater_than: 0}
  validates :min_confidence, numericality: {greater_than_or_equal_to: 0, less_than_or_equal_to: 100}
  validates :max_signals_per_hour, numericality: {greater_than: 0}
  validates :evaluation_interval_seconds, numericality: {greater_than: 0}
  validates :strategy_risk_fraction, numericality: {greater_than: 0, less_than_or_equal_to: 1}
  validates :strategy_tp_target, numericality: {greater_than: 0}
  validates :strategy_sl_target, numericality: {greater_than: 0}

  scope :active, -> { where(active: true) }

  before_validation :normalize_slug

  def activate!
    self.class.transaction do
      self.class.lock(true).load
      self.class.update_all(active: false)
      update!(active: true)
    end
    TradingConfiguration.reset_profile_cache!
  end

  private

  def normalize_slug
    self.slug = slug.to_s.parameterize if slug.present?
  end
end
