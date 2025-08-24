# frozen_string_literal: true

class TradingPair < ApplicationRecord
  validates :product_id, presence: true, uniqueness: true

  scope :enabled, -> { where(enabled: true) }
  scope :current_month, -> { where("expiration_date >= ? AND expiration_date <= ?", Date.current.beginning_of_month, Date.current.end_of_month) }
  scope :upcoming_month, -> { where("expiration_date >= ? AND expiration_date <= ?", Date.current.next_month.beginning_of_month, Date.current.next_month.end_of_month) }
  scope :not_expired, -> { where("expiration_date > ?", Date.current) }
  scope :active, -> { enabled.not_expired }
  scope :tradeable, -> { enabled.where("expiration_date > ?", Date.current + 1.day) } # Avoid contracts expiring tomorrow

  # Parse contract information from product_id
  # Examples: ET-29AUG25-CDE, BIT-29AUG25-CDE
  def self.parse_contract_info(product_id)
    return nil unless product_id

    # Match pattern: PREFIX-DDMMMYY-SUFFIX
    match = product_id.match(/^([A-Z]+)-(\d{2}[A-Z]{3}\d{2})-([A-Z]+)$/)
    return nil unless match

    prefix, date_str, suffix = match.captures

    # Parse the date (e.g., "29AUG25" -> Date)
    begin
      expiration_date = Date.strptime(date_str, "%d%b%y")
    rescue Date::Error
      return nil
    end

    # Map prefix to base currency
    base_currency = case prefix
    when "BIT" then "BTC"
    when "ET" then "ETH"
    else prefix
    end

    {
      base_currency: base_currency,
      quote_currency: "USD",
      expiration_date: expiration_date,
      contract_type: suffix
    }
  end

  # Check if contract is expired
  def expired?
    expiration_date && expiration_date < Date.current
  end

  # Check if this is a current month contract
  def current_month?
    return false unless expiration_date

    current_month_range = Date.current.beginning_of_month..Date.current.end_of_month
    current_month_range.cover?(expiration_date)
  end

  # Check if this is an upcoming month contract
  def upcoming_month?
    return false unless expiration_date

    upcoming_month_range = Date.current.next_month.beginning_of_month..Date.current.next_month.end_of_month
    upcoming_month_range.cover?(expiration_date)
  end

  # Check if contract is available for trading (not expiring too soon)
  def tradeable?
    return false unless expiration_date
    expiration_date > Date.current + 1.day
  end

  # Get the underlying asset symbol (BTC, ETH, etc.)
  def underlying_asset
    # All contracts are now futures contracts, parse from product_id
    contract_info = self.class.parse_contract_info(product_id)
    contract_info&.dig(:base_currency) || base_currency
  end

  # Get current month futures contracts for a given asset
  def self.current_month_for_asset(asset)
    enabled
      .current_month
      .where(base_currency: asset)
      .order(:expiration_date)
  end

  # Get upcoming month futures contracts for a given asset
  def self.upcoming_month_for_asset(asset)
    enabled
      .upcoming_month
      .where(base_currency: asset)
      .order(:expiration_date)
  end

  # Get the best available contract for trading (prefer current month, fall back to upcoming)
  def self.best_available_for_asset(asset)
    current_month_contracts = current_month_for_asset(asset).tradeable
    return current_month_contracts.first if current_month_contracts.any?

    upcoming_month_contracts = upcoming_month_for_asset(asset).tradeable
    upcoming_month_contracts.first
  end
end
