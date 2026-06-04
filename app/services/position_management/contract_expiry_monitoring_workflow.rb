# frozen_string_literal: true

module PositionManagement
  class ContractExpiryMonitoringWorkflow
    include AlertPolicy

    attr_reader :logger

    def initialize(expiry_manager: ContractExpiryManager.new(logger: Rails.logger), logger: Rails.logger)
      @expiry_manager = expiry_manager
      @logger = logger
    end

    def call(buffer_days: nil, emergency_check: false)
      alerts = []
      buffer_days ||= ENV.fetch("CONTRACT_EXPIRY_BUFFER_DAYS", "2").to_i

      logger.info("Starting contract expiry monitoring workflow (emergency: #{emergency_check})")

      metadata = if emergency_check
        perform_emergency_check
      else
        perform_regular_monitoring(buffer_days, alerts)
      end

      metadata[:buffer_days] = buffer_days
      metadata[:emergency_check] = emergency_check
      logger.info("Contract expiry monitoring workflow completed successfully")

      WorkflowResult.new(
        workflow: "contract_expiry_monitoring",
        status: :success,
        metadata: metadata,
        alerts: alerts
      )
    rescue => e
      logger.error("Contract expiry monitoring workflow failed: #{e.message}")
      logger.error(e.backtrace.join("\n")) if e.backtrace

      notify(
        alerts,
        severity: "error",
        title: "Contract Expiry Monitoring Failed",
        message: "Critical workflow failed: #{e.message}. Manual intervention may be required."
      )

      raise
    end

    private

    def perform_regular_monitoring(buffer_days, alerts)
      logger.info("Performing regular expiry monitoring with #{buffer_days}d buffer")

      report = @expiry_manager.generate_expiry_report
      log_expiry_report(report)

      expiring_positions = @expiry_manager.positions_approaching_expiry(buffer_days)
      closed_count = 0

      if expiring_positions.any?
        logger.warn("Found #{expiring_positions.size} positions expiring within #{buffer_days} days")

        expiring_positions.each do |position|
          days = position.days_until_expiry
          margin_impact = position.margin_impact_near_expiry

          logger.warn(
            "Expiring position: #{position.product_id} (#{position.side} #{position.size}) " \
            "expires in #{days} days, margin impact: #{margin_impact[:reason]}"
          )
        end

        closed_count = @expiry_manager.close_expiring_positions(buffer_days)

        if closed_count > 0
          logger.info("Closed #{closed_count}/#{expiring_positions.size} expiring positions")
        else
          logger.warn("No positions were successfully closed despite #{expiring_positions.size} expiring")
          notify(
            alerts,
            severity: "error",
            title: "Failed to Close Expiring Positions",
            message: "Found #{expiring_positions.size} positions expiring within #{buffer_days} days but could not close any. " \
                     "Manual intervention required."
          )
        end
      else
        logger.info("No positions expiring within #{buffer_days} days")
      end

      margin_warnings = @expiry_manager.check_margin_requirements_near_expiry(5)
      if margin_warnings.any?
        logger.warn("Found #{margin_warnings.size} positions with increased margin requirements near expiry")
      end

      validation_results = @expiry_manager.validate_expiry_dates
      invalid_count = validation_results.count { |result| !result[:valid] }

      if invalid_count > 0
        logger.error("Found #{invalid_count} positions with invalid expiry dates")
        notify(
          alerts,
          severity: "warning",
          title: "Invalid Contract Expiry Dates",
          message: "Found #{invalid_count} positions with unparseable expiry dates. Review required."
        )
      end

      {
        expiring_positions_count: expiring_positions.size,
        closed_count: closed_count,
        margin_warnings_count: margin_warnings.size,
        invalid_expiry_count: invalid_count
      }
    end

    def perform_emergency_check
      logger.info("Performing emergency expiry check")

      expired_positions = Position.expired_positions
      closed_expired_count = 0

      if expired_positions.any?
        logger.error("EMERGENCY: Found #{expired_positions.size} expired positions")

        expired_positions.each do |position|
          days = position.days_until_expiry
          logger.error(
            "EXPIRED position: #{position.product_id} (#{position.side} #{position.size}) " \
            "expired #{days.abs} days ago"
          )
        end

        closed_expired_count = @expiry_manager.close_expired_positions

        if closed_expired_count > 0
          logger.error("EMERGENCY: Closed #{closed_expired_count}/#{expired_positions.size} expired positions")
        else
          logger.error("EMERGENCY: Could not close any expired positions - CRITICAL ISSUE")

          SlackNotificationService.alert(
            "error",
            "CRITICAL: Cannot Close Expired Positions",
            "Found #{expired_positions.size} expired positions but could not close any. IMMEDIATE MANUAL INTERVENTION REQUIRED."
          )
        end
      else
        logger.info("Emergency check: No expired positions found")
      end

      today_expiring = @expiry_manager.positions_approaching_expiry(0)
      closed_today_count = 0

      if today_expiring.any?
        logger.warn("Emergency check: Found #{today_expiring.size} positions expiring today")
        closed_today_count = @expiry_manager.close_expiring_positions(0)

        if closed_today_count > 0
          logger.info("Emergency check: Closed #{closed_today_count} positions expiring today")
        end
      end

      {
        expired_positions_count: expired_positions.size,
        closed_expired_count: closed_expired_count,
        today_expiring_count: today_expiring.size,
        closed_today_count: closed_today_count
      }
    end

    def log_expiry_report(report)
      logger.info("=== Contract Expiry Report ===")
      logger.info("Total open positions: #{report[:total_positions]}")
      logger.info("Positions with known expiry: #{report[:positions_with_known_expiry]}")
      logger.info("Expiring today: #{report[:expiring_today]}")
      logger.info("Expiring tomorrow: #{report[:expiring_tomorrow]}")
      logger.info("Expiring within week: #{report[:expiring_within_week]}")
      logger.info("Already expired: #{report[:expired]}")

      if report[:by_days].any?
        logger.info("Breakdown by days until expiry:")
        report[:by_days].each do |days, count|
          days_str = days.nil? ? "unknown" : days.to_s
          logger.info("  #{days_str} days: #{count} positions")
        end
      end

      logger.info("=== End Report ===")
    end
  end
end
