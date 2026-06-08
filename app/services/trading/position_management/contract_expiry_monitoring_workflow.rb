# frozen_string_literal: true

module Trading
  module PositionManagement
    class ContractExpiryMonitoringWorkflow < BaseWorkflow
      WORKFLOW_NAME = "contract_expiry_monitoring"

      def initialize(logger: Rails.logger, expiry_manager: nil)
        super(logger: logger)
        @expiry_manager = expiry_manager || ContractExpiryManager.new(logger: logger)
      end

      def call(buffer_days: nil, emergency_check: false)
        buffer_days ||= ENV.fetch("CONTRACT_EXPIRY_BUFFER_DAYS", "2").to_i

        logger.info("Starting contract expiry monitoring workflow (emergency: #{emergency_check})")

        result = if emergency_check
          perform_emergency_check
        else
          perform_regular_monitoring(buffer_days)
        end

        workflow_result(
          workflow: WORKFLOW_NAME,
          status: result[:status],
          details: result[:details].merge(buffer_days: buffer_days, emergency_check: emergency_check)
        )
      end

      private

      def perform_regular_monitoring(buffer_days)
        logger.info("Performing regular expiry monitoring with #{buffer_days}d buffer")

        report = @expiry_manager.generate_expiry_report
        log_expiry_report(report)

        expiring_positions = @expiry_manager.positions_approaching_expiry(buffer_days)
        closed_count = handle_expiring_positions(expiring_positions, buffer_days)

        margin_warnings = @expiry_manager.check_margin_requirements_near_expiry(5)
        logger.warn("Found #{margin_warnings.size} positions with increased margin requirements near expiry") if margin_warnings.any?

        validation_results = @expiry_manager.validate_expiry_dates
        invalid_count = validation_results.count { |result| !result[:valid] }
        handle_invalid_expiry_dates(invalid_count)

        {
          status: (expiring_positions.any? && closed_count.zero?) ? :warning : :success,
          details: {
            expiring_positions: expiring_positions.size,
            closed_count: closed_count,
            margin_warnings: margin_warnings.size,
            invalid_expiry_dates: invalid_count
          }
        }
      end

      def perform_emergency_check
        logger.info("Performing emergency expiry check")

        expired_positions = Position.expired_positions
        expired_closed_count = handle_expired_positions(expired_positions)

        today_expiring = @expiry_manager.positions_approaching_expiry(0)
        today_closed_count = handle_positions_expiring_today(today_expiring)

        {
          status: (expired_positions.any? && expired_closed_count.zero?) ? :warning : :success,
          details: {
            expired_positions: expired_positions.size,
            expired_closed_count: expired_closed_count,
            expiring_today: today_expiring.size,
            today_closed_count: today_closed_count
          }
        }
      end

      def handle_expiring_positions(expiring_positions, buffer_days)
        if expiring_positions.any?
          logger.warn("Found #{expiring_positions.size} positions expiring within #{buffer_days} days")
          expiring_positions.each do |position|
            margin_impact = position.margin_impact_near_expiry
            logger.warn(
              "Expiring position: #{position.product_id} (#{position.side} #{position.size}) " \
              "expires in #{position.days_until_expiry} days, margin impact: #{margin_impact[:reason]}"
            )
          end

          closed_count = @expiry_manager.close_expiring_positions(buffer_days)

          if closed_count.positive?
            logger.info("Closed #{closed_count}/#{expiring_positions.size} expiring positions")
          else
            logger.warn("No positions were successfully closed despite #{expiring_positions.size} expiring")
            send_alert(
              "error",
              "Failed to Close Expiring Positions",
              "Found #{expiring_positions.size} positions expiring within #{buffer_days} days but could not close any. Manual intervention required."
            )
          end

          closed_count
        else
          logger.info("No positions expiring within #{buffer_days} days")
          0
        end
      end

      def handle_invalid_expiry_dates(invalid_count)
        return if invalid_count.zero?

        logger.error("Found #{invalid_count} positions with invalid expiry dates")
        send_alert(
          "warning",
          "Invalid Contract Expiry Dates",
          "Found #{invalid_count} positions with unparseable expiry dates. Review required."
        )
      end

      def handle_expired_positions(expired_positions)
        if expired_positions.any?
          logger.error("EMERGENCY: Found #{expired_positions.size} expired positions")
          expired_positions.each do |position|
            logger.error(
              "EXPIRED position: #{position.product_id} (#{position.side} #{position.size}) " \
              "expired #{position.days_until_expiry.abs} days ago"
            )
          end

          closed_count = @expiry_manager.close_expired_positions
          if closed_count.positive?
            logger.error("EMERGENCY: Closed #{closed_count}/#{expired_positions.size} expired positions")
          else
            logger.error("EMERGENCY: Could not close any expired positions - CRITICAL ISSUE")
            send_alert(
              "error",
              "CRITICAL: Cannot Close Expired Positions",
              "Found #{expired_positions.size} expired positions but could not close any. IMMEDIATE MANUAL INTERVENTION REQUIRED."
            )
          end

          closed_count
        else
          logger.info("Emergency check: No expired positions found")
          0
        end
      end

      def handle_positions_expiring_today(today_expiring)
        return 0 if today_expiring.empty?

        logger.warn("Emergency check: Found #{today_expiring.size} positions expiring today")
        closed_count = @expiry_manager.close_expiring_positions(0)
        logger.info("Emergency check: Closed #{closed_count} positions expiring today") if closed_count.positive?
        closed_count
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
            logger.info("  #{days.nil? ? "unknown" : days} days: #{count} positions")
          end
        end

        logger.info("=== End Report ===")
      end
    end
  end
end
