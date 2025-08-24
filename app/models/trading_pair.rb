# frozen_string_literal: true

class TradingPair < ApplicationRecord
  validates :product_id, presence: true, uniqueness: true
  
  scope :enabled, -> { where(enabled: true) }
  scope :perpetual, -> { where(is_perpetual: true) }
  scope :current_month, -> { where(is_perpetual: false).where('expiration_date >= ? AND expiration_date <= ?', Date.current.beginning_of_month, Date.current.end_of_month) }
  scope :not_expired, -> { where('expiration_date IS NULL OR expiration_date > ?', Date.current) }
  scope :futures_contracts, -> { where(is_perpetual: false) }

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
      expiration_date = Date.strptime(date_str, '%d%b%y')
    rescue Date::Error
      return nil
    end
    
    # Map prefix to base currency
    base_currency = case prefix
    when 'BIT' then 'BTC'
    when 'ET' then 'ETH'
    else prefix
    end
    
    {
      base_currency: base_currency,
      quote_currency: 'USD',
      expiration_date: expiration_date,
      contract_type: suffix,
      is_perpetual: false
    }
  end

  # Check if contract is expired
  def expired?
    return false if is_perpetual?
    expiration_date && expiration_date < Date.current
  end

  # Check if this is a current month contract
  def current_month?
    return false if is_perpetual?
    return false unless expiration_date
    
    current_month_range = Date.current.beginning_of_month..Date.current.end_of_month
    current_month_range.cover?(expiration_date)
  end

  # Get the underlying asset symbol (BTC, ETH, etc.)
  def underlying_asset
    return base_currency if is_perpetual?
    
    # For futures contracts, parse from product_id
    contract_info = self.class.parse_contract_info(product_id)
    contract_info&.dig(:base_currency) || base_currency
  end

  # Get current month futures contracts for a given asset
  def self.current_month_for_asset(asset)
    enabled
      .futures_contracts
      .current_month
      .where(base_currency: asset)
      .order(:expiration_date)
  end
end
