# frozen_string_literal: true

# Background job for monitoring contract expiry and closing positions before expiration
class ContractExpiryMonitoringJob < ApplicationJob
  include SentryServiceTracking

  queue_as :critical
  retry_on StandardError, wait: :exponentially_longer, attempts: 3

  def perform(buffer_days: nil, emergency_check: false)
    logger = Rails.logger
    result = PositionManagement::ContractExpiryMonitoringWorkflow.new(logger: logger).call(
      buffer_days: buffer_days,
      emergency_check: emergency_check
    )
    logger.info("Contract expiry monitoring job result: #{result.to_h}")
    result
  end
end
