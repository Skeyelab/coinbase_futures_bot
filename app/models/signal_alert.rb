# frozen_string_literal: true

class SignalAlert < ApplicationRecord
  include SentryTrackable

  belongs_to :trading_pair, foreign_key: :symbol, primary_key: :product_id, optional: true

  validates :symbol, :side, :signal_type, :strategy_name, :confidence, presence: true
  validates :symbol, format: {with: /\A[A-Z0-9-]+\z/, message: "must be valid trading symbol"}
  validates :side, inclusion: {in: %w[long short buy sell unknown]}
  validates :signal_type, inclusion: {in: %w[entry exit stop_loss take_profit]}
  validates :alert_status, inclusion: {in: %w[active triggered expired cancelled]}, allow_nil: true
  validates :confidence, numericality: {greater_than: 0, less_than_or_equal_to: 100}
  validates :entry_price, :stop_loss, :take_profit, numericality: {greater_than: 0}, allow_nil: true
  validates :quantity, numericality: {only_integer: true, greater_than: 0}, allow_nil: true
  validates :timeframe, inclusion: {in: %w[1m 5m 15m 1h 6h 1d]}, allow_nil: true

  before_create :set_defaults

  scope :active, -> { where(alert_status: "active") }
  scope :triggered, -> { where(alert_status: "triggered") }
  scope :expired, -> { where(alert_status: "expired") }
  scope :cancelled, -> { where(alert_status: "cancelled") }
  scope :for_symbol, ->(symbol) { where(symbol: symbol) }
  scope :by_strategy, ->(strategy_name) { where(strategy_name: strategy_name) }
  scope :by_side, ->(side) { where(side: side) }
  scope :high_confidence, ->(threshold = 70) { where("confidence >= ?", threshold) }
  scope :recent, ->(hours = 24) { where("alert_timestamp >= ?", hours.hours.ago) }
  scope :expiring_soon, ->(minutes = 60) { where("expires_at <= ?", minutes.minutes.from_now) }
  scope :entry_signals, -> { where(signal_type: "entry") }
  scope :exit_signals, -> { where(signal_type: %w[exit stop_loss take_profit]) }

  # Class methods for creating different types of signals
  def self.create_entry_signal!(symbol:, side:, strategy_name:, confidence:, entry_price:,
    stop_loss:, take_profit:, quantity:, timeframe:,
    metadata: {}, strategy_data: {})
    create!(
      symbol: symbol,
      side: side,
      signal_type: "entry",
      strategy_name: strategy_name,
      confidence: confidence,
      entry_price: entry_price,
      stop_loss: stop_loss,
      take_profit: take_profit,
      quantity: quantity,
      timeframe: timeframe,
      alert_status: "active",
      alert_timestamp: Time.current.utc,
      expires_at: calculate_expiry(strategy_name, timeframe),
      metadata: metadata,
      strategy_data: strategy_data
    )
  end

  def self.create_exit_signal!(symbol:, signal_type:, strategy_name:, confidence:,
    entry_price:, quantity:, metadata: {}, strategy_data: {})
    create!(
      symbol: symbol,
      side: determine_exit_side(signal_type),
      signal_type: signal_type,
      strategy_name: strategy_name,
      confidence: confidence,
      entry_price: entry_price,
      quantity: quantity,
      alert_status: "active",
      alert_timestamp: Time.current.utc,
      expires_at: 5.minutes.from_now.utc, # Exit signals expire quickly
      metadata: metadata,
      strategy_data: strategy_data
    )
  end

  # Instance methods
  def triggered?
    alert_status == "triggered"
  end

  def active?
    alert_status == "active"
  end

  def expired?
    alert_status == "expired" || (expires_at && expires_at < Time.current)
  end

  def trigger!
    update!(alert_status: "triggered", triggered_at: Time.current.utc)
  end

  def cancel!
    update!(alert_status: "cancelled")
  end

  def expire!
    update!(alert_status: "expired")
  end

  def long?
    %w[long buy].include?(side)
  end

  def short?
    %w[short sell].include?(side)
  end

  def entry_signal?
    signal_type == "entry"
  end

  def exit_signal?
    %w[exit stop_loss take_profit].include?(signal_type)
  end

  def to_api_response
    {
      id: id,
      symbol: symbol,
      side: side,
      signal_type: signal_type,
      strategy_name: strategy_name,
      confidence: confidence.to_f,
      entry_price: entry_price&.to_f,
      stop_loss: stop_loss&.to_f,
      take_profit: take_profit&.to_f,
      quantity: quantity,
      timeframe: timeframe,
      alert_status: alert_status,
      alert_timestamp: alert_timestamp.iso8601,
      expires_at: expires_at&.iso8601,
      metadata: metadata,
      created_at: created_at.iso8601,
      updated_at: updated_at.iso8601
    }
  end

  def self.calculate_expiry(strategy_name, timeframe)
    # Default expiry based on strategy and timeframe
    case strategy_name
    when "MultiTimeframeSignal"
      case timeframe
      when "1m" then 2.minutes.from_now.utc
      when "5m" then 5.minutes.from_now.utc
      when "15m" then 15.minutes.from_now.utc
      when "1h" then 1.hour.from_now.utc
      else 30.minutes.from_now.utc
      end
    else
      15.minutes.from_now.utc
    end
  end

  def self.determine_exit_side(signal_type)
    case signal_type
    when "stop_loss", "take_profit"
      # For exit signals, side depends on original position
      # This would need to be determined from position context
    end
    "unknown"
  end

  private

  def set_defaults
    self.alert_status ||= "active"
    self.alert_timestamp ||= Time.current.utc
    self.expires_at ||= self.class.calculate_expiry(strategy_name, timeframe)
  end
end
