# frozen_string_literal: true

class DayTradingPositionManagementJob < ApplicationJob
  queue_as :critical

  def perform
    logger = Rails.logger
    result = PositionManagement::DayTradingManagementWorkflow.new(logger: logger).call
    logger.info("Day trading position management job result: #{result.to_h}")
    result
  end
end
