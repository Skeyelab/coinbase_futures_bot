# frozen_string_literal: true

class PositionImportService
  include SentryServiceTracking

  def initialize
    @coinbase_client = Coinbase::Client.new
  end

  def import_positions_from_coinbase
    track_service_call("import_positions_from_coinbase") do
      Rails.logger.info("[PIS] Starting position import from Coinbase...")

      # Test authentication first
      auth_result = @coinbase_client.test_auth
      unless auth_result[:advanced_trade][:ok]
        raise "Coinbase authentication failed: #{auth_result[:advanced_trade][:message]}"
      end

      # Fetch positions from Coinbase
      coinbase_positions = @coinbase_client.futures_positions
      Rails.logger.info("[PIS] Found #{coinbase_positions.size} positions on Coinbase")

      imported_count = 0
      updated_count = 0
      errors = []

      coinbase_positions.each do |cb_position|
        result = sync_position(cb_position)
        case result[:action]
        when :created
          imported_count += 1
          Rails.logger.info("[PIS] Imported new position: #{result[:position].product_id}")
        when :updated
          updated_count += 1
          Rails.logger.info("[PIS] Updated existing position: #{result[:position].product_id}")
        when :skipped
          Rails.logger.debug("[PIS] Skipped position: #{cb_position["product_id"]} - #{result[:reason]}")
        end
      rescue => e
        error_msg = "Failed to sync position #{cb_position["product_id"]}: #{e.message}"
        Rails.logger.error("[PIS] #{error_msg}")
        errors << error_msg
      end

      # Log summary
      Rails.logger.info("[PIS] Import complete: #{imported_count} imported, #{updated_count} updated, #{errors.size} errors")

      {
        imported: imported_count,
        updated: updated_count,
        errors: errors,
        total_coinbase: coinbase_positions.size
      }
    end
  rescue => e
    Rails.logger.error("[PIS] Position import failed: #{e.message}")
    Sentry.capture_exception(e)
    raise
  end

  def sync_position(coinbase_position)
    product_id = coinbase_position["product_id"]
    size = coinbase_position["number_of_contracts"].to_f
    side = coinbase_position["side"]&.upcase
    entry_price = coinbase_position["avg_entry_price"]&.to_f
    unrealized_pnl = coinbase_position["unrealized_pnl"]&.to_f

    # Skip if no size (closed position)
    return {action: :skipped, reason: "No size"} if size.zero?

    # Skip if missing required data
    return {action: :skipped, reason: "Missing required data"} unless product_id && side && entry_price

    # Convert Coinbase side to our format
    position_side = case side.downcase
    when "long", "buy" then "LONG"
    when "short", "sell" then "SHORT"
    else
      return {action: :skipped, reason: "Unknown side: #{side}"}
    end

    # Try to find existing position by product_id and side
    existing_position = Position.open
      .where(product_id: product_id, side: position_side)
      .order(:entry_time)
      .last

    if existing_position
      # Update existing position
      existing_position.update!(
        size: size,
        entry_price: entry_price,
        pnl: unrealized_pnl,
        updated_at: Time.current
      )

      {action: :updated, position: existing_position}
    else
      # Create new position
      new_position = Position.create!(
        product_id: product_id,
        side: position_side,
        size: size,
        entry_price: entry_price,
        entry_time: Time.current, # Use current time since we don't have entry time from Coinbase
        status: "OPEN",
        pnl: unrealized_pnl,
        day_trading: determine_day_trading_status(product_id),
        take_profit: nil, # Will be set by strategy if needed
        stop_loss: nil    # Will be set by strategy if needed
      )

      {action: :created, position: new_position}
    end
  end

  def clear_all_positions
    track_service_call("clear_all_positions") do
      count = Position.count
      Position.delete_all
      Rails.logger.info("[PIS] Cleared #{count} positions from database")
      count
    end
  end

  def import_and_replace
    track_service_call("import_and_replace") do
      Rails.logger.info("[PIS] Starting full position replacement...")

      # Clear existing positions
      cleared_count = clear_all_positions

      # Import from Coinbase
      result = import_positions_from_coinbase

      {
        cleared: cleared_count,
        imported: result[:imported],
        updated: result[:updated],
        errors: result[:errors],
        total_coinbase: result[:total_coinbase]
      }
    end
  end

  private

  def determine_day_trading_status(product_id)
    # For now, assume all positions are day trading
    # In the future, this could be determined by position age or other factors
    true
  end
end
