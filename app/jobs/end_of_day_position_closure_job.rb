# frozen_string_literal: true

class EndOfDayPositionClosureJob < ApplicationJob
  queue_as :critical

  def perform
    logger = Rails.logger
    logger.info("Starting end-of-day position closure job")
    result = Trading::PositionManagement::EndOfDayClosureWorkflow.new(logger: logger).call
    logger.info(result.summary)
    logger.info("Completed end-of-day position closure job") unless result.noop?
  rescue => e
    logger&.error("End-of-day position closure job failed: #{e.message}")
    logger&.error(e.backtrace.join("\n"))

    raise
  end
end
