class TestJob < ApplicationJob
  queue_as :default

  def perform(message = "Hello, GoodJob!")
    Rails.logger.info("[TestJob] #{message}")
  end
end
