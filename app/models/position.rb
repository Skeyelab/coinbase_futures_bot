# frozen_string_literal: true

class Position < ApplicationRecord
  include SentryTrackable
  # Validations
  validates :product_id, presence: true
  validates :side, presence: true, inclusion: {in: %w[LONG SHORT]}
  validates :size, presence: true, numericality: {greater_than: 0}
  validates :entry_price, presence: true, numericality: {greater_than: 0}
  validates :entry_time, presence: true
  validates :status, presence: true, inclusion: {in: %w[OPEN CLOSED]}
  validates :day_trading, inclusion: {in: [true, false]}

  # Scopes
  scope :open, -> { where(status: "OPEN") }
  scope :closed, -> { where(status: "CLOSED") }
  scope :day_trading, -> { where(day_trading: true) }
  scope :swing_trading, -> { where(day_trading: false) }
  scope :by_product, ->(product_id) { where(product_id: product_id) }
  scope :by_side, ->(side) { where(side: side) }
  scope :by_asset, ->(asset) { where("product_id LIKE ?", "#{asset}%") }
  scope :opened_today, -> { where("DATE(entry_time) = ?", Date.current) }
  scope :opened_yesterday, -> { where("entry_time < ? AND entry_time >= ?", 24.hours.ago, 48.hours.ago) }
  scope :expiring_soon, -> { day_trading.opened_yesterday.open }

  # Callbacks
  before_validation :set_defaults
  after_create :log_position_opened
  after_update :log_position_updated

  # Associations
  belongs_to :trading_pair, primary_key: :product_id, foreign_key: :product_id, optional: true

  # Instance methods
  def open?
    status == "OPEN"
  end

  def closed?
    status == "CLOSED"
  end

  def long?
    side == "LONG"
  end

  def short?
    side == "SHORT"
  end

  def duration
    return nil unless entry_time
    return Time.current - entry_time if open?

    close_time - entry_time if close_time
  end

  def duration_hours
    duration&.fdiv(1.hour)
  end

  def duration_minutes
    duration&.fdiv(1.minute)
  end

  def age_in_hours
    return nil unless entry_time

    (Time.current - entry_time) / 1.hour
  end

  def age_in_minutes
    return nil unless entry_time

    (Time.current - entry_time) / 1.minute
  end

  def needs_same_day_closure?
    day_trading? && open? && self.class.opened_yesterday.exists?(id: id)
  end

  def needs_closure_soon?
    day_trading? && open? && age_in_hours.to_f > 23.5
  end

  def calculate_pnl(current_price)
    return 0 unless open? && current_price
    return 0 unless entry_price

    if long?
      ((current_price - entry_price) / entry_price) * size
    else
      ((entry_price - current_price) / entry_price) * size
    end
  end

  def hit_take_profit?(current_price)
    return false unless take_profit && current_price
    return false unless entry_price

    if long?
      current_price >= take_profit
    else
      current_price <= take_profit
    end
  end

  def hit_stop_loss?(current_price)
    return false unless stop_loss && current_price
    return false unless entry_price

    if long?
      current_price <= stop_loss
    else
      current_price >= stop_loss
    end
  end

  def close_position!(close_price, close_time = Time.current)
    update!(
      status: "CLOSED",
      close_time: close_time,
      pnl: calculate_pnl(close_price)
    )
  end

  def force_close!(close_price, reason = "Day trading closure", close_time = Time.current)
    update!(
      status: "CLOSED",
      close_time: close_time,
      pnl: calculate_pnl(close_price)
    )
    Rails.logger.info("Position #{id} force closed: #{reason} at #{close_price}")
  end

  # Class methods
  def self.open_day_trading_positions
    day_trading.open.opened_today
  end

  def self.positions_needing_closure
    day_trading.open.opened_yesterday
  end

  def self.positions_approaching_closure
    day_trading.open.where("entry_time < ?", 23.hours.ago)
  end

  def self.close_all_day_trading_positions(close_price, reason = "End of day closure")
    positions = day_trading.open
    closed_count = 0

    positions.each do |position|
      position.force_close!(close_price, reason)
      closed_count += 1
    rescue => e
      Rails.logger.error("Failed to close position #{position.id}: #{e.message}")
    end

    Rails.logger.info("Closed #{closed_count} day trading positions for #{reason}")
    closed_count
  end

  def self.cleanup_old_positions(days_old = 30)
    old_positions = closed.where("close_time < ?", days_old.days.ago)
    count = old_positions.count
    old_positions.destroy_all
    Rails.logger.info("Cleaned up #{count} old closed positions")
    count
  end

  private

  def set_defaults
    self.status ||= "OPEN"
    self.entry_time ||= Time.current
    self.day_trading = Rails.application.config.default_day_trading if day_trading.nil?
  end

  def log_position_opened
    Rails.logger.info("Position opened: #{side} #{size} #{product_id} at #{entry_price} (Day trading: #{day_trading})")
  end

  def log_position_updated
    return unless saved_change_to_status? && status == "CLOSED"

    Rails.logger.info("Position closed: #{side} #{size} #{product_id} with PnL: #{pnl}")
  end
end
