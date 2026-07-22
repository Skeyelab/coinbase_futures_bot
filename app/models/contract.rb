# frozen_string_literal: true

class Contract < ApplicationRecord
  include SentryTrackable

  belongs_to :underlying, optional: true

  validates :product_id, presence: true, uniqueness: true

  # Coinbase product-ID prefix => the asset the contract actually tracks.
  # Dated contracts (BIT/ET/NOL) and CDE perps (BIP/XPP) share one product-ID
  # shape — `PREFIX-DDMMMYY-CDE` — so only the prefix distinguishes them, and
  # perps carry a 2030 dummy expiry rather than a real one.
  #
  # This map is the single source of truth for which products we ingest at all:
  # MarketData::CoinbaseRest#upsert_products builds its filter from these keys,
  # so adding a perp here starts candle collection for it. Enabling a symbol for
  # TRADING is a separate decision — see Trading::SymbolSuspension and ADR 0002's
  # no-evidence-inheritance rule: a new perp collects data while suspended until
  # it earns enablement on its own walk-forward.
  PREFIX_TO_BASE_CURRENCY = {
    "BIT" => "BTC",   # dated nano BTC
    "ET" => "ETH",    # dated nano ETH
    "NOL" => "OIL",   # dated nano oil
    "BIP" => "BTC",   # BTC perp — ADR 0002 home instrument
    "XPP" => "XRP"    # XRP perp — ADR 0002 designated second seat
  }.freeze

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

    # Unmapped prefixes fall back to the prefix itself. That is deliberately
    # lossy but visible: an unmapped perp would resolve underlying_asset to
    # e.g. "BIP" and silently get no spot reference feed, which is why
    # PREFIX_TO_BASE_CURRENCY gates ingestion in the first place.
    base_currency = PREFIX_TO_BASE_CURRENCY.fetch(prefix, prefix)

    {
      base_currency: base_currency,
      quote_currency: "USD",
      expiration_date: expiration_date,
      contract_type: suffix
    }
  end

  def self.parse_expiry_date(product_id)
    return nil unless product_id.is_a?(String)

    match = product_id.match(/^[A-Z]+-(\d{1,2}[A-Z]{3}\d{2})-[A-Z]+$/)
    return nil unless match

    date_str = (match[1].length == 6) ? "0#{match[1]}" : match[1]
    Date.strptime(date_str, "%d%b%y")
  rescue Date::Error
    nil
  end

  def self.days_until_expiry(product_id)
    expiry_date = parse_expiry_date(product_id)
    return nil unless expiry_date

    (expiry_date - Date.current).to_i
  end

  def self.parse_expiry_from_api(api_response)
    if api_response["expiration_time"]
      begin
        Time.parse(api_response["expiration_time"]).to_date
      rescue ArgumentError => e
        Rails.logger.warn("Failed to parse API expiration_time '#{api_response["expiration_time"]}': #{e.message}")
        parse_expiry_date(api_response["product_id"]) if api_response["product_id"]
      end
    elsif api_response["product_id"]
      parse_expiry_date(api_response["product_id"])
    end
  end

  def self.get_expiry_info(product_id, positions_service: nil)
    result = {
      product_id: product_id,
      parsed_date: parse_expiry_date(product_id),
      days_until_expiry: days_until_expiry(product_id),
      api_expiry_time: nil,
      api_days_until_expiry: nil
    }

    if positions_service
      begin
        response = positions_service.list_open_positions(product_id: product_id)
        if response.is_a?(Array) && response.any?
          pos = response.first
          if pos["expiration_time"]
            result[:api_expiry_time] = pos["expiration_time"]
            api_date = Time.parse(pos["expiration_time"]).to_date
            result[:api_days_until_expiry] = (api_date - Date.current).to_i
          end
        end
      rescue => e
        Rails.logger.warn("Failed to fetch API expiry info for #{product_id}: #{e.message}")
      end
    end

    result
  end

  def self.expiring_soon?(product_id, buffer_days = 2)
    days = days_until_expiry(product_id)
    return false unless days

    days <= buffer_days
  end

  def self.expired?(product_id) = expired_contract?(product_id)

  def self.expired_contract?(product_id)
    days = days_until_expiry(product_id)
    return false unless days

    days < 0
  end

  def self.find_expiring_positions(buffer_days = 2)
    Position.open.select { |p| expiring_soon?(p.product_id, buffer_days) }
  end

  def self.find_expired_positions
    Position.open.select { |p| expired_contract?(p.product_id) }
  end

  MARGIN_TIERS = [
    [0..1, 2.0, "Expiry within 24 hours - double margin"],
    [2..3, 1.5, "Expiry within 3 days - 50% higher margin"],
    [4..7, 1.2, "Expiry within 1 week - 20% higher margin"]
  ].freeze

  def self.margin_impact_near_expiry(product_id)
    days = days_until_expiry(product_id)
    return nil unless days

    tier = MARGIN_TIERS.find { |range, _, _| range.cover?(days) }
    tier ? {multiplier: tier[1], reason: tier[2]} : {multiplier: 1.0, reason: "Normal margin requirements"}
  end

  def self.format_expiry_summary(positions)
    return "No positions to summarize" if positions.empty?

    positions.group_by { |p| days_until_expiry(p.product_id) }.map do |days, pos_list|
      count = pos_list.size
      products = pos_list.map(&:product_id).uniq.join(", ")

      case days
      when nil then "#{count} positions with unknown expiry: #{products}"
      when 0 then "#{count} positions expiring TODAY: #{products}"
      when 1 then "#{count} positions expiring TOMORROW: #{products}"
      else "#{count} positions expiring in #{days} days: #{products}"
      end
    end.join("\n")
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
