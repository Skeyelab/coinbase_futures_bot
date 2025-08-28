# frozen_string_literal: true

# Test Effectiveness Validation Module
# This module helps ensure tests are actually testing real behavior, not just mocks

module TestEffectiveness
  # Track mock usage in tests
  def self.track_mock_usage(example, object, method_name)
    example.metadata[:mock_count] ||= 0
    example.metadata[:mock_count] += 1
    example.metadata[:mocked_methods] ||= []
    example.metadata[:mocked_methods] << "#{object.class.name}##{method_name}"

    # Warn about mocking critical business logic methods
    critical_methods = %i[
      calculate_total_pnl
      get_current_prices
      check_tp_sl_triggers
      close_positions
      fetch_candles
      list_open_positions
      execute_trade
    ]

    return unless critical_methods.include?(method_name.to_sym)

    puts "🚨 CRITICAL: Test '#{example.full_description}' is mocking critical business method '#{method_name}'"
    puts '   Consider using integration testing instead of mocking core business logic'
  end

  # Validate that a test actually exercises real code paths
  def self.validate_real_code_execution(example)
    return if example.metadata[:integration_test]

    mock_count = example.metadata[:mock_count] || 0
    mocked_methods = example.metadata[:mocked_methods] || []

    # Flag tests that mock too many methods
    return unless mock_count > 5

    puts "🔴 HIGH RISK: Test '#{example.full_description}' uses #{mock_count} mocks"
    puts "   Mocked methods: #{mocked_methods.join(', ')}"
    puts '   This test may not be validating actual behavior'
  end

  # Mark a test as an integration test
  def self.mark_as_integration_test(example)
    example.metadata[:integration_test] = true
  end
end

# NOTE: Monkey patching removed due to CI compatibility issues
# The test effectiveness tracking will rely on the existing hooks in rails_helper.rb

# Add helper methods to RSpec configuration
RSpec.configure do |config|
  config.after(:each) do |example|
    TestEffectiveness.validate_real_code_execution(example)
  end

  # Helper method to mark tests as integration tests
  config.extend(Module.new do
    def integration_test(description, *args, &block)
      describe(description, *args) do
        before(:each) do
          TestEffectiveness.mark_as_integration_test(example)
        end

        class_eval(&block)
      end
    end
  end)
end
