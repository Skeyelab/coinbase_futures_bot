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
  validates :trailing_stop_enabled, inclusion: {in: [true, false]}

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
  scope :older_than, ->(hours) { where("entry_time < ?", hours.hours.ago) }
  scope :open_swing_positions, -> { swing_trading.open }
  scope :trailing_stop_managed, -> { open.where(trailing_stop_enabled: true) }

  # Contract expiry scopes
  scope :expiring_within_days, ->(days) {
    open.select { |p| p.days_until_expiry && p.days_until_expiry <= days }
  }
  scope :contract_expiring_soon, ->(buffer_days = 2) {
    open.select { |p| p.expiring_soon?(buffer_days) }
  }
  scope :contract_expiring_today, -> {
    open.select { |p| p.days_until_expiry == 0 }
  }
  scope :contract_expired, -> {
    open.select { |p| p.expired? }
  }

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

  # Contract expiry methods
  def days_until_expiry
    FuturesContract.days_until_expiry(product_id)
  end

  def expiring_soon?(buffer_days = 2)
    FuturesContract.expiring_soon?(product_id, buffer_days)
  end

  def expired?
    FuturesContract.expired?(product_id)
  end

  def expiry_date
    FuturesContract.parse_expiry_date(product_id)
  end

  def needs_expiry_closure?(buffer_days = 2)
    open? && expiring_soon?(buffer_days)
  end

  def margin_impact_near_expiry
    FuturesContract.margin_impact_near_expiry(product_id)
  end

  def get_current_market_price
    # Try to get current price from recent market data
    # First try recent ticks
    recent_tick = Tick.where(product_id: product_id)
      .order(observed_at: :desc)
      .first

    return recent_tick.price if recent_tick && recent_tick.observed_at > 5.minutes.ago

    # Fall back to most recent 1-minute candle
    recent_candle = Candle.for_symbol(product_id)
      .one_minute
      .order(timestamp: :desc)
      .first

    return recent_candle.close if recent_candle && recent_candle.timestamp > 5.minutes.ago

    # If no recent data, log warning and return nil
    Rails.logger.warn("No recent price data for #{product_id}")
    nil
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

  def pnl_percentage
    return nil unless closed? && entry_price && pnl

    # Calculate percentage based on PnL and position size
    # PnL = (exit_price - entry_price) * size for long positions
    # PnL = (entry_price - exit_price) * size for short positions
    # So percentage = (PnL / (entry_price * size)) * 100
    percentage = (pnl / (entry_price * size)) * 100

    percentage.round(2)
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

  def trailing_stop_active?
    trailing_stop_enabled? && open?
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

  # Contract expiry class methods
  def self.positions_approaching_expiry(buffer_days = 2)
    FuturesContract.find_expiring_positions(buffer_days)
  end

  def self.positions_expiring_today
    FuturesContract.find_expiring_positions(0)
  end

  def self.expired_positions
    FuturesContract.find_expired_positions
  end

  def self.close_expiring_positions(buffer_days = 2, close_price = nil, reason = "Contract expiry")
    positions = positions_approaching_expiry(buffer_days)
    return 0 if positions.empty?

    closed_count = 0
    positions.each do |position|
      current_price = close_price || position.get_current_market_price
      next unless current_price

      position.force_close!(current_price, reason)
      closed_count += 1
    rescue => e
      Rails.logger.error("Failed to close expiring position #{position.id}: #{e.message}")
    end

    Rails.logger.info("Closed #{closed_count} positions approaching contract expiry")
    closed_count
  end

  def self.emergency_close_expired_positions(close_price = nil)
    positions = expired_positions
    return 0 if positions.empty?

    Rails.logger.error("EMERGENCY: Found #{positions.size} expired positions")
    closed_count = 0

    positions.each do |position|
      current_price = close_price || position.get_current_market_price
      next unless current_price

      position.force_close!(current_price, "EMERGENCY: Contract expired")
      closed_count += 1
    rescue => e
      Rails.logger.error("Failed to close expired position #{position.id}: #{e.message}")
    end

    Rails.logger.error("EMERGENCY: Closed #{closed_count} expired positions")
    closed_count
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
