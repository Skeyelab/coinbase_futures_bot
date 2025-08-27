# frozen_string_literal: true

# Helper to prevent hanging tests
module TimeoutHelper
  def self.with_timeout(seconds = 30, &block)
    require 'timeout'

    Timeout.timeout(seconds, &block)
  rescue Timeout::Error
    raise "Test timed out after #{seconds} seconds"
  end
end

# Add timeout to RSpec examples with different levels
RSpec.configure do |config|
  config.around(:each) do |example|
    # Use longer timeout for known slow tests
    timeout_seconds = case example.full_description
                      when /upsert.*candles/ then 60 # Candle tests are slow
                      when /MarketDataSubscribeJob/ then 45 # Subscription tests need time
                      when /integration/ then 45 # Integration tests
                      else 30 # Default timeout
                      end

    TimeoutHelper.with_timeout(timeout_seconds) do
      example.run
    end
  end
end
