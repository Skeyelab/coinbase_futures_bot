# frozen_string_literal: true

class SwingPositionManagementJob < ApplicationJob
  queue_as :critical

  def perform
    logger = Rails.logger
    logger.info("Starting swing position management job")
    result = Trading::PositionManagement::SwingManagementWorkflow.new(logger: logger).call
    logger.info(result.summary)
    logger.info("Swing position management job completed successfully")
  rescue => e
    logger&.error("Swing position management job failed: #{e.message}")
    logger&.error(e.backtrace.join("\n"))

    Sentry.with_scope do |scope|
      scope.set_tag("job_type", "swing_position_management")
      scope.set_tag("critical", true)
      scope.set_context("job_failure", {
        error_class: e.class.to_s,
        error_message: e.message,
        backtrace: e.backtrace&.first(10)
      })

      Sentry.capture_exception(e)
    end

    # Alert via Slack for critical job failure
    SlackNotificationService.alert(
      "critical",
      "Swing Position Management Job Failed",
      "Critical swing position management job failed: #{e.message}"
    )

    # PostHog: Track critical job failure
    PostHog.capture(
      distinct_id: "system",
      event: "critical_job_failed",
      properties: {
        job_class: self.class.name,
        error_class: e.class.to_s,
        error_message: e.message
      }
    )

    raise
  end
end
