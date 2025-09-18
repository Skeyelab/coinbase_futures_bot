# frozen_string_literal: true

# Background job for monitoring contract expiry and closing positions before expiration
class ContractExpiryMonitoringJob < ApplicationJob
  include SentryServiceTracking

  queue_as :critical  # High priority for expiry management

  # Retry configuration for critical expiry monitoring
  retry_on StandardError, wait: :exponentially_longer, attempts: 3

  def perform(buffer_days: nil, emergency_check: false)
    @logger = Rails.logger
    @logger.info("Starting contract expiry monitoring job (emergency: #{emergency_check})")

    # Use environment configuration or default values
    buffer_days ||= ENV.fetch("CONTRACT_EXPIRY_BUFFER_DAYS", "2").to_i

    @expiry_manager = ContractExpiryManager.new(logger: @logger)

    if emergency_check
      perform_emergency_check
    else
      perform_regular_monitoring(buffer_days)
    end

    @logger.info("Contract expiry monitoring job completed successfully")
  rescue => e
    @logger.error("Contract expiry monitoring job failed: #{e.message}")
    @logger.error(e.backtrace.join("\n")) if e.backtrace

    # Send critical alert for job failure
    SlackNotificationService.alert(
      "error",
      "Contract Expiry Monitoring Failed",
      "Critical job failed: #{e.message}. Manual intervention may be required."
    )

    raise # Re-raise to trigger retry mechanism
  end

  private

  def perform_regular_monitoring(buffer_days)
    @logger.info("Performing regular expiry monitoring with #{buffer_days}d buffer")

    # Generate and log comprehensive expiry report
    report = @expiry_manager.generate_expiry_report
    log_expiry_report(report)

    # Check for positions expiring soon
    expiring_positions = @expiry_manager.positions_approaching_expiry(buffer_days)

    if expiring_positions.any?
      @logger.warn("Found #{expiring_positions.size} positions expiring within #{buffer_days} days")

      # Log detailed information about each expiring position
      expiring_positions.each do |position|
        days = position.days_until_expiry
        margin_impact = position.margin_impact_near_expiry

        @logger.warn(
          "Expiring position: #{position.product_id} (#{position.side} #{position.size}) " \
          "expires in #{days} days, margin impact: #{margin_impact[:reason]}"
        )
      end

      # Close positions with buffer
      closed_count = @expiry_manager.close_expiring_positions(buffer_days)

      if closed_count > 0
        @logger.info("Closed #{closed_count}/#{expiring_positions.size} expiring positions")
      else
        @logger.warn("No positions were successfully closed despite #{expiring_positions.size} expiring")

        # Send alert if positions are expiring but couldn't be closed
        SlackNotificationService.alert(
          "error",
          "Failed to Close Expiring Positions",
          "Found #{expiring_positions.size} positions expiring within #{buffer_days} days but could not close any. Manual intervention required."
        )
      end
    else
      @logger.info("No positions expiring within #{buffer_days} days")
    end

    # Check margin requirements for positions expiring within 5 days
    margin_warnings = @expiry_manager.check_margin_requirements_near_expiry(5)
    if margin_warnings.any?
      @logger.warn("Found #{margin_warnings.size} positions with increased margin requirements near expiry")
    end

    # Validate expiry dates for all open positions (periodic health check)
    validation_results = @expiry_manager.validate_expiry_dates
    invalid_count = validation_results.count { |r| !r[:valid] }

    if invalid_count > 0
      @logger.error("Found #{invalid_count} positions with invalid expiry dates")
      SlackNotificationService.alert(
        "warning",
        "Invalid Contract Expiry Dates",
        "Found #{invalid_count} positions with unparseable expiry dates. Review required."
      )
    end
  end

  def perform_emergency_check
    @logger.info("Performing emergency expiry check")

    # Check for already expired positions
    expired_positions = Position.expired_positions

    if expired_positions.any?
      @logger.error("EMERGENCY: Found #{expired_positions.size} expired positions")

      # Log detailed information about each expired position
      expired_positions.each do |position|
        days = position.days_until_expiry
        @logger.error(
          "EXPIRED position: #{position.product_id} (#{position.side} #{position.size}) " \
          "expired #{days.abs} days ago"
        )
      end

      # Emergency closure of expired positions
      closed_count = @expiry_manager.close_expired_positions

      if closed_count > 0
        @logger.error("EMERGENCY: Closed #{closed_count}/#{expired_positions.size} expired positions")
      else
        @logger.error("EMERGENCY: Could not close any expired positions - CRITICAL ISSUE")

        # Send critical alert
        SlackNotificationService.alert(
          "error",
          "CRITICAL: Cannot Close Expired Positions",
          "Found #{expired_positions.size} expired positions but could not close any. IMMEDIATE MANUAL INTERVENTION REQUIRED."
        )
      end
    else
      @logger.info("Emergency check: No expired positions found")
    end

    # Also check for positions expiring today as part of emergency check
    today_expiring = @expiry_manager.positions_approaching_expiry(0)

    if today_expiring.any?
      @logger.warn("Emergency check: Found #{today_expiring.size} positions expiring today")
      closed_count = @expiry_manager.close_expiring_positions(0)

      if closed_count > 0
        @logger.info("Emergency check: Closed #{closed_count} positions expiring today")
      end
    end
  end

  def log_expiry_report(report)
    @logger.info("=== Contract Expiry Report ===")
    @logger.info("Total open positions: #{report[:total_positions]}")
    @logger.info("Positions with known expiry: #{report[:positions_with_known_expiry]}")
    @logger.info("Expiring today: #{report[:expiring_today]}")
    @logger.info("Expiring tomorrow: #{report[:expiring_tomorrow]}")
    @logger.info("Expiring within week: #{report[:expiring_within_week]}")
    @logger.info("Already expired: #{report[:expired]}")

    if report[:by_days].any?
      @logger.info("Breakdown by days until expiry:")
      report[:by_days].each do |days, count|
        days_str = days.nil? ? "unknown" : days.to_s
        @logger.info("  #{days_str} days: #{count} positions")
      end
    end

    @logger.info("=== End Report ===")
  end
end
