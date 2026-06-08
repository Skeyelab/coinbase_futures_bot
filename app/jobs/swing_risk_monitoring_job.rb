# frozen_string_literal: true

class SwingRiskMonitoringJob < ApplicationJob
  queue_as :default

  def perform
    logger = Rails.logger
    logger.info("Starting swing risk monitoring job")
    result = Trading::PositionManagement::SwingRiskMonitoringWorkflow.new(logger: logger).call
    logger.info(result.summary)
    logger.info("Swing risk monitoring job completed successfully") unless result.noop?
  rescue => e
    logger&.error("Swing risk monitoring job failed: #{e.message}")
    logger&.error(e.backtrace.join("\n"))

    Sentry.with_scope do |scope|
      scope.set_tag("job_type", "swing_risk_monitoring")
      scope.set_context("job_failure", {
        error_class: e.class.to_s,
        error_message: e.message
      })

      Sentry.capture_exception(e)
    end

    # Don't re-raise for monitoring jobs - they should not fail the queue
  end
end
