# frozen_string_literal: true

class DayTradingPositionManagementJob < ApplicationJob
  queue_as :critical

  def perform
    logger = Rails.logger
    logger.info("Starting day trading position management job")
    result = Trading::PositionManagement::DayTradingWorkflow.new(logger: logger).call
    logger.info(result.summary)
    logger.info("Completed day trading position management job")
  rescue => e
    logger&.error("Day trading position management job failed: #{e.message}")
    logger&.error(e.backtrace.join("\n"))

    SlackNotificationService.alert(
      "error",
      "Day Trading Position Management Error",
      "Job failed: #{e.message}"
    )

    raise
  end
end
