# frozen_string_literal: true

class Contract < ApplicationRecord
  include SentryTrackable

  belongs_to :underlying, optional: true

  validates :product_id, presence: true, uniqueness: true

  scope :enabled, -> { where(enabled: true) }
  scope :current_month, -> { where("expiration_date >= ? AND expiration_date <= ?", Date.current.beginning_of_month, Date.current.end_of_month) }
  scope :upcoming_month, -> { where("expiration_date >= ? AND expiration_date <= ?", Date.current.next_month.beginning_of_month, Date.current.next_month.end_of_month) }
  scope :not_expired, -> { where("expiration_date > ?", Date.current) }
  scope :active, -> { enabled.not_expired }
  scope :tradeable, -> { enabled.where("expiration_date > ?", Date.current + 1.day) }

  def self.parse_contract_info(product_id)
    return nil unless product_id

    match = product_id.match(/^([A-Z]+)-(\d{2}[A-Z]{3}\d{2})-([A-Z]+)$/)
    return nil unless match

    prefix, date_str, suffix = match.captures

    begin
      expiration_date = Date.strptime(date_str, "%d%b%y")
    rescue Date::Error
      return nil
    end

    base_currency = case prefix
    when "BIT" then "BTC"
    when "ET" then "ETH"
    when "NOL" then "OIL"
    else prefix
    end

    {
      base_currency: base_currency,
      quote_currency: "USD",
      expiration_date: expiration_date,
      contract_type: suffix
    }
  end

  def expired?
    expiration_date && expiration_date < Date.current
  end

  def current_month?
    return false unless expiration_date

    (Date.current.beginning_of_month..Date.current.end_of_month).cover?(expiration_date)
  end

  def upcoming_month?
    return false unless expiration_date

    (Date.current.next_month.beginning_of_month..Date.current.next_month.end_of_month).cover?(expiration_date)
  end

  def tradeable?
    return false unless expiration_date

    expiration_date > Date.current + 1.day
  end

  def underlying_asset
    contract_info = self.class.parse_contract_info(product_id)
    contract_info&.dig(:base_currency) || base_currency
  end

  def self.current_month_for_asset(asset)
    enabled.current_month.where(base_currency: asset).order(:expiration_date)
  end

  def self.upcoming_month_for_asset(asset)
    enabled.upcoming_month.where(base_currency: asset).order(:expiration_date)
  end

  def self.best_available_for_asset(asset)
    current_month_contracts = current_month_for_asset(asset).tradeable
    return current_month_contracts.first if current_month_contracts.any?

    upcoming_month_for_asset(asset).tradeable.first
  end
end
