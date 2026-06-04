# frozen_string_literal: true

class SwingPositionManagementJob < ApplicationJob
  queue_as :critical

  def perform
    logger = Rails.logger
    result = PositionManagement::SwingManagementWorkflow.new(logger: logger).call
    logger.info("Swing position management job result: #{result.to_h}")
    result
  end
end
