# frozen_string_literal: true

# Utility class for parsing and managing futures contract expiry dates
class FuturesContract
  include SentryServiceTracking

  # Parse expiry date from Coinbase futures product ID
  # Examples:
  # "BIT-29AUG25-CDE" -> August 29, 2025
  # "ET-15SEP25-CDE" -> September 15, 2025
  def self.parse_expiry_date(product_id)
    return nil unless product_id.is_a?(String)

    # Match the Coinbase futures product ID format: BIT-DDMMMYY-CDE or ET-DDMMMYY-CDE
    match = product_id.match(/^(BIT|ET)-(\d{1,2})([A-Z]{3})(\d{2})-[A-Z]+$/)
    return nil unless match

    day = match[2].to_i
    month_abbr = match[3]
    year_suffix = match[4].to_i

    # Convert month abbreviation to month number
    month = month_abbreviation_to_number(month_abbr)
    return nil unless month

    # Convert 2-digit year to 4-digit year
    # Assume 00-30 means 2000-2030, 31-99 means 1931-1999
    year = (year_suffix <= 30) ? 2000 + year_suffix : 1900 + year_suffix

    begin
      Date.new(year, month, day)
    rescue Date::Error
      Rails.logger.warn("Invalid date components for #{product_id}: #{year}-#{month}-#{day}")
      nil
    end
  end

  # Calculate days until contract expiry
  def self.days_until_expiry(product_id)
    expiry_date = parse_expiry_date(product_id)
    return nil unless expiry_date

    (expiry_date - Date.current).to_i
  end

  # Enhanced expiry detection using Coinbase API data when available
  def self.parse_expiry_from_api(api_response)
    # Use expiration_time from API if available
    if api_response["expiration_time"]
      begin
        Time.parse(api_response["expiration_time"]).to_date
      rescue ArgumentError => e
        Rails.logger.warn("Failed to parse API expiration_time '#{api_response["expiration_time"]}': #{e.message}")
        # Fallback to product ID parsing
        parse_expiry_date(api_response["product_id"]) if api_response["product_id"]
      end
    elsif api_response["product_id"]
      # Fallback to product ID parsing
      parse_expiry_date(api_response["product_id"])
    else
      nil
    end
  end

  # Get comprehensive expiry information for a product
  def self.get_expiry_info(product_id, positions_service: nil)
    result = {
      product_id: product_id,
      parsed_date: parse_expiry_date(product_id),
      days_until_expiry: days_until_expiry(product_id),
      api_expiry_time: nil,
      api_days_until_expiry: nil
    }

    # Try to fetch from Coinbase API for accurate expiry data if service provided
    if positions_service
      begin
        response = positions_service.list_open_positions(product_id: product_id)
        if response.is_a?(Array) && response.any?
          position = response.first
          if position["expiration_time"]
            result[:api_expiry_time] = position["expiration_time"]
            api_date = Time.parse(position["expiration_time"]).to_date
            result[:api_days_until_expiry] = (api_date - Date.current).to_i
          end
        end
      rescue => e
        Rails.logger.warn("Failed to fetch API expiry info for #{product_id}: #{e.message}")
      end
    end

    result
  end

  # Check if a contract is expiring within the specified buffer days
  def self.expiring_soon?(product_id, buffer_days = 2)
    days = days_until_expiry(product_id)
    return false unless days
    days <= buffer_days
  end

  # Check if a contract has already expired
  def self.expired?(product_id)
    days = days_until_expiry(product_id)
    return false unless days
    days < 0
  end

  # Get all expiring contracts from positions
  def self.find_expiring_positions(buffer_days = 2)
    Position.open.select do |position|
      expiring_soon?(position.product_id, buffer_days)
    end
  end

  # Get all expired positions
  def self.find_expired_positions
    Position.open.select do |position|
      expired?(position.product_id)
    end
  end

  # Calculate margin requirement changes near expiry
  def self.margin_impact_near_expiry(product_id)
    days = days_until_expiry(product_id)
    return nil unless days

    case days
    when 0..1
      {multiplier: 2.0, reason: "Expiry within 24 hours - double margin"}
    when 2..3
      {multiplier: 1.5, reason: "Expiry within 3 days - 50% higher margin"}
    when 4..7
      {multiplier: 1.2, reason: "Expiry within 1 week - 20% higher margin"}
    else
      {multiplier: 1.0, reason: "Normal margin requirements"}
    end
  end

  # Format expiry information for logging/alerts
  def self.format_expiry_summary(positions)
    return "No positions to summarize" if positions.empty?

    summary = positions.group_by { |p| days_until_expiry(p.product_id) }.map do |days, pos_list|
      count = pos_list.size
      products = pos_list.map(&:product_id).uniq.join(", ")

      case days
      when nil
        "#{count} positions with unknown expiry: #{products}"
      when 0
        "#{count} positions expiring TODAY: #{products}"
      when 1
        "#{count} positions expiring TOMORROW: #{products}"
      when (2..7)
        "#{count} positions expiring in #{days} days: #{products}"
      else
        "#{count} positions expiring in #{days} days: #{products}"
      end
    end

    summary.join("\n")
  end

  # Convert month abbreviation to month number
  def self.month_abbreviation_to_number(month_abbr)
    months = {
      "JAN" => 1, "FEB" => 2, "MAR" => 3, "APR" => 4,
      "MAY" => 5, "JUN" => 6, "JUL" => 7, "AUG" => 8,
      "SEP" => 9, "OCT" => 10, "NOV" => 11, "DEC" => 12
    }
    months[month_abbr.upcase]
  end
  private_class_method :month_abbreviation_to_number
end
