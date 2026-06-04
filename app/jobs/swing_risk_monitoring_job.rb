# frozen_string_literal: true

class SwingRiskMonitoringJob < ApplicationJob
  queue_as :default

  def perform
    logger = Rails.logger
    result = PositionManagement::SwingRiskMonitoringWorkflow.new(logger: logger).call
    logger.info("Swing risk monitoring job result: #{result.to_h}")
    result
  end
end
