# frozen_string_literal: true

class EndOfDayPositionClosureJob < ApplicationJob
  queue_as :critical

  def perform
    logger = Rails.logger
    result = PositionManagement::EndOfDayClosureWorkflow.new(logger: logger).call
    logger.info("End-of-day position closure job result: #{result.to_h}")
    result
  end
end
