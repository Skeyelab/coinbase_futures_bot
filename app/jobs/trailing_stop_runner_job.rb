# frozen_string_literal: true

class TrailingStopRunnerJob < ApplicationJob
  queue_as :critical

  def perform
    logger = Rails.logger
    runner = Trading::TrailingStop::Runner.new(logger: logger)
    result = runner.close_triggered_positions(positions: Position.open)

    logger.info("TrailingStopRunnerJob processed=#{result[:processed_ids].size} closed=#{result[:closed_count]}")
    result
  rescue => e
    Rails.logger.error("TrailingStopRunnerJob failed: #{e.message}")
    raise
  end
end
