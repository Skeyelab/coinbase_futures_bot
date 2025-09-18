# frozen_string_literal: true

# Service class for managing contract expiry monitoring and position closures
class ContractExpiryManager
  include SentryServiceTracking

  # Financial calculation constants
  ESTIMATED_CONTRACT_VALUE = 50_000.0  # Estimated value per contract in USD
  ESTIMATED_MARGIN_RATE = 0.1          # Estimated margin requirement (10%)

  def initialize(logger: Rails.logger)
    @logger = logger
    @positions_service = Trading::CoinbasePositions.new(logger: logger)
    @slack_service = SlackNotificationService
  end

  # Find positions approaching expiry within the buffer days
  def positions_approaching_expiry(buffer_days = 2)
    positions = Position.open.to_a
    expiring_positions = positions.select { |p| p.expiring_soon?(buffer_days) }

    if expiring_positions.any?
      @logger.info("Found #{expiring_positions.size} positions approaching expiry within #{buffer_days} days")
      expiring_positions.each do |position|
        days = position.days_until_expiry
        @logger.info("  - #{position.product_id}: #{position.side} #{position.size} contracts, expires in #{days} days")
      end
    end

    expiring_positions
  end

  # Close positions before expiry with comprehensive error handling
  def close_expiring_positions(buffer_days = 2)
    positions = positions_approaching_expiry(buffer_days)
    return 0 if positions.empty?

    @logger.warn("Closing #{positions.size} positions approaching expiry within #{buffer_days} days")
    closed_count = 0

    positions.each do |position|
      closed_count += close_single_position(position, "Contract expiry (#{buffer_days}d buffer)")
    rescue => e
      @logger.error("Failed to close expiring position #{position.id}: #{e.message}")
      track_sentry_exception(e, {
        position_id: position.id,
        product_id: position.product_id,
        days_until_expiry: position.days_until_expiry,
        operation: "close_expiring_position"
      })
    end

    if closed_count > 0
      notify_expiry_closures(closed_count, buffer_days, "warning")
    end

    closed_count
  end

  # Emergency closure of expired positions
  def close_expired_positions
    positions = Position.expired_positions
    return 0 if positions.empty?

    @logger.error("EMERGENCY: Closing #{positions.size} expired positions")
    closed_count = 0

    positions.each do |position|
      closed_count += close_single_position(position, "EMERGENCY: Contract expired")
    rescue => e
      @logger.error("Failed to close expired position #{position.id}: #{e.message}")
      track_sentry_exception(e, {
        position_id: position.id,
        product_id: position.product_id,
        days_until_expiry: position.days_until_expiry,
        operation: "emergency_close_expired_position"
      })
    end

    if closed_count > 0
      notify_expiry_closures(closed_count, 0, "error", emergency: true)
    end

    closed_count
  end

  # Check margin requirements near expiry
  def check_margin_requirements_near_expiry(buffer_days = 5)
    positions = positions_approaching_expiry(buffer_days)
    margin_warnings = []

    positions.each do |position|
      margin_impact = position.margin_impact_near_expiry
      next unless margin_impact && margin_impact[:multiplier] > 1.0

      @logger.warn("Position #{position.id} has increased margin requirements: #{margin_impact[:reason]}")
      margin_warnings << {
        position: position,
        margin_impact: margin_impact
      }
    end

    if margin_warnings.any?
      notify_margin_warnings_near_expiry(margin_warnings)
    end

    margin_warnings
  end

  # Monitor balance impact during expiry closures
  def monitor_balance_during_expiry_closures(buffer_days = 2)
    # Note: This would require implementing margin/balance monitoring service
    # For now, we'll log the intention and return basic info
    positions = positions_approaching_expiry(buffer_days)
    return {closed_count: 0, margin_freed: 0} if positions.empty?

    total_size = positions.sum(&:size)
    @logger.info("Monitoring balance impact for #{positions.size} positions (total size: #{total_size})")

    # Close positions and track the impact
    closed_count = close_expiring_positions(buffer_days)

    # Estimate margin freed (simplified calculation)
    # In production, this would query actual margin requirements from Coinbase API
    estimated_margin_freed = total_size * ESTIMATED_CONTRACT_VALUE * ESTIMATED_MARGIN_RATE

    if closed_count > 0 && estimated_margin_freed > 1000
      @logger.info("Estimated #{estimated_margin_freed.round} margin freed by closing #{closed_count} expiring positions")

      @slack_service.alert(
        "info",
        "Margin Freed from Expiry Closures",
        "Freed approximately $#{estimated_margin_freed.round} margin by closing #{closed_count} expiring positions."
      )
    end

    {
      closed_count: closed_count,
      margin_freed: estimated_margin_freed.round
    }
  end

  # Get comprehensive expiry report
  def generate_expiry_report
    all_open_positions = Position.open.to_a

    # Group positions by days until expiry
    grouped_positions = all_open_positions.group_by { |p| p.days_until_expiry }

    report = {
      total_positions: all_open_positions.size,
      positions_with_known_expiry: all_open_positions.count { |p| p.days_until_expiry },
      expiring_today: grouped_positions[0]&.size || 0,
      expiring_tomorrow: grouped_positions[1]&.size || 0,
      expiring_within_week: (0..7).sum { |days| grouped_positions[days]&.size || 0 },
      expired: all_open_positions.count { |p| p.expired? },
      by_days: grouped_positions.transform_values(&:size).sort_by { |days, _| days || Float::INFINITY }
    }

    @logger.info("Contract Expiry Report: #{report}")
    report
  end

  # Validate all position expiry dates
  def validate_expiry_dates
    positions = Position.open.to_a
    validation_results = []

    positions.each do |position|
      expiry_info = FuturesContract.get_expiry_info(position.product_id, positions_service: @positions_service)

      result = {
        position_id: position.id,
        product_id: position.product_id,
        parsed_expiry: expiry_info[:parsed_date],
        days_until_expiry: expiry_info[:days_until_expiry],
        api_expiry: expiry_info[:api_expiry_time],
        api_days_until_expiry: expiry_info[:api_days_until_expiry],
        valid: expiry_info[:parsed_date].present?
      }

      validation_results << result

      unless result[:valid]
        @logger.warn("Invalid expiry date for position #{position.id} (#{position.product_id})")
      end
    end

    @logger.info("Validated expiry dates for #{positions.size} positions")
    validation_results
  end

  private

  # Close a single position with comprehensive error handling
  def close_single_position(position, reason)
    @logger.info("Closing position #{position.id} (#{position.product_id}): #{reason}")

    begin
      # Try to close via Coinbase API first
      result = @positions_service.close_position(product_id: position.product_id)

      if result["success"] || result["order_id"]
        @logger.info("Successfully closed position #{position.id} via API")
        1
      else
        @logger.warn("API closure failed for position #{position.id}, using local closure")
        # Fall back to local closure
        current_price = position.get_current_market_price
        if current_price
          position.force_close!(current_price, reason)
          @logger.info("Successfully closed position #{position.id} locally")
          1
        else
          @logger.error("Cannot close position #{position.id}: no current price available")
          0
        end
      end
    rescue => e
      @logger.error("API closure failed for position #{position.id}: #{e.message}")
      # Fall back to local closure
      current_price = position.get_current_market_price
      if current_price
        position.force_close!(current_price, reason)
        @logger.info("Successfully closed position #{position.id} locally after API failure")
        1
      else
        @logger.error("Cannot close position #{position.id}: API failed and no current price available")
        0
      end
    end
  end

  # Send Slack notifications for expiry closures
  def notify_expiry_closures(closed_count, buffer_days, severity, emergency: false)
    title = emergency ? "EMERGENCY: Expired Contracts" : "Contract Expiry Alert"

    message = if emergency
      "Closed #{closed_count} expired positions. Immediate attention required!"
    else
      "Closed #{closed_count} positions approaching contract expiry (#{buffer_days}d buffer)."
    end

    @slack_service.alert(severity, title, message)
  rescue => e
    @logger.error("Failed to send expiry closure notification: #{e.message}")
  end

  # Send Slack notifications for margin warnings near expiry
  def notify_margin_warnings_near_expiry(margin_warnings)
    return if margin_warnings.empty?

    message_lines = ["Margin requirement increases near contract expiry:"]

    margin_warnings.each do |warning|
      position = warning[:position]
      impact = warning[:margin_impact]
      days = position.days_until_expiry

      message_lines << "• #{position.product_id}: #{impact[:reason]} (expires in #{days} days)"
    end

    @slack_service.alert(
      "warning",
      "Margin Warning Near Expiry",
      message_lines.join("\n")
    )
  rescue => e
    @logger.error("Failed to send margin warning notification: #{e.message}")
  end

  # Track exceptions to Sentry with context
  def track_sentry_exception(exception, context = {})
    # This would integrate with Sentry for error tracking
    # For now, just log the error with context
    @logger.error("Sentry tracking: #{exception.class}: #{exception.message}")
    @logger.error("Context: #{context.inspect}")
  end
end
