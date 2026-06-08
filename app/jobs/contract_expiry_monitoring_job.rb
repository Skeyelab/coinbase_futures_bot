# frozen_string_literal: true

# Background job for monitoring contract expiry and closing positions before expiration
class ContractExpiryMonitoringJob < ApplicationJob
  include SentryServiceTracking

  queue_as :critical  # High priority for expiry management

  # Retry configuration for critical expiry monitoring
  retry_on StandardError, wait: :exponentially_longer, attempts: 3

  def perform(buffer_days: nil, emergency_check: false)
    logger = Rails.logger
    logger.info("Starting contract expiry monitoring job (emergency: #{emergency_check})")
    result = Trading::PositionManagement::ContractExpiryMonitoringWorkflow.new(logger: logger).call(
      buffer_days: buffer_days,
      emergency_check: emergency_check
    )
    logger.info(result.summary)
    logger.info("Contract expiry monitoring job completed successfully")
  rescue => e
    logger&.error("Contract expiry monitoring job failed: #{e.message}")
    logger&.error(e.backtrace.join("\n")) if e.backtrace

    SlackNotificationService.alert(
      "error",
      "Contract Expiry Monitoring Failed",
      "Critical job failed: #{e.message}. Manual intervention may be required."
    )

    raise # Re-raise to trigger retry mechanism
  end
end
