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
    return unless ENV["VERBOSE_TESTS"] == "true"

    puts "🚨 CRITICAL: Test '#{example.full_description}' is mocking critical business method '#{method_name}'"
    puts "   Consider using integration testing instead of mocking core business logic"
  end

  # Validate that a test actually exercises real code paths
  def self.validate_real_code_execution(example)
    return if example.metadata[:integration_test]

    mock_count = example.metadata[:mock_count] || 0
    mocked_methods = example.metadata[:mocked_methods] || []

    # Flag tests that mock too many methods
    return unless mock_count > 5
    return unless ENV["VERBOSE_TESTS"] == "true"

    puts "🔴 HIGH RISK: Test '#{example.full_description}' uses #{mock_count} mocks"
    puts "   Mocked methods: #{mocked_methods.join(", ")}"
    puts "   This test may not be validating actual behavior"
  end

  # Mark a test as an integration test
  def self.mark_as_integration_test(example)
    example.metadata[:integration_test] = true
  end

  # CI-specific logging and verification methods
  def self.log_execution_environment
    return unless ENV["RSPEC_DEBUG"] == "1"

    puts "=== TEST EXECUTION ENVIRONMENT ==="
    puts "Rails env: #{Rails.env}"
    puts "Database: #{ActiveRecord::Base.connection.current_database}"
    puts "Test files: #{Dir.glob("spec/**/*_spec.rb").count}"
    puts "CI detected: #{ENV["CI"]}"
    puts "Test effectiveness loaded: #{defined?(TestEffectiveness)}"
    puts "RSpec loaded: #{defined?(RSpec)}"
  end

  def self.verify_real_execution
    log_execution_environment

    # Force some real operations to verify environment
    if defined?(Position)
      count = Position.count
      puts "Current Position count: #{count}" if ENV["RSPEC_DEBUG"] == "1"
    end

    if defined?(TradingPair)
      count = TradingPair.count
      puts "Current TradingPair count: #{count}" if ENV["RSPEC_DEBUG"] == "1"
    end

    # Verify database tables exist
    tables = ActiveRecord::Base.connection.tables
    puts "Database tables: #{tables.join(", ")}" if ENV["RSPEC_DEBUG"] == "1"

    # Verify we can perform real operations
    begin
      if defined?(Position)
        test_pos = Position.create!(
          product_id: "VERIFY-TEST",
          side: "LONG",
          size: 1.0,
          entry_price: 100.0,
          entry_time: Time.current,
          status: "OPEN",
          day_trading: true
        )
        if ENV["RSPEC_DEBUG"] == "1"
          puts "✅ Real Position creation verified (ID: #{test_pos.id})"
        end
        test_pos.destroy
        puts "✅ Real Position deletion verified" if ENV["RSPEC_DEBUG"] == "1"
      end
    rescue => e
      warn "❌ Real database operations failed: #{e.message}"
      raise e
    end
  end

  def self.ci_verification_summary
    return unless ENV["CI"]
    return unless ENV["RSPEC_DEBUG"] == "1"

    puts "=== CI VERIFICATION SUMMARY ==="
    puts "Environment: #{Rails.env}"
    puts "Database: #{ActiveRecord::Base.connection.current_database}"
    puts "Test files found: #{Dir.glob("spec/**/*_spec.rb").count}"
    puts "Test effectiveness module: #{defined?(TestEffectiveness) ? "LOADED" : "MISSING"}"
    puts "RSpec configuration: #{defined?(RSpec) ? "LOADED" : "MISSING"}"
    puts "ActiveRecord connection: #{ActiveRecord::Base.connected? ? "ACTIVE" : "INACTIVE"}"
  end
end

# NOTE: Monkey patching removed due to CI compatibility issues
# The test effectiveness tracking will rely on the existing hooks in rails_helper.rb

# Add helper methods to RSpec configuration
RSpec.configure do |config|
  config.after(:each) do |example|
    TestEffectiveness.validate_real_code_execution(example)
  end

  # CI-specific configuration (quiet by default; set RSPEC_DEBUG=1 for diagnostics)
  if ENV["CI"]
    config.before(:suite) do
      TestEffectiveness.verify_real_execution
    end

    config.after(:suite) do
      TestEffectiveness.ci_verification_summary
    end
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
