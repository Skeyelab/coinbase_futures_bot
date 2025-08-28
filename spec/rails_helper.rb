# frozen_string_literal: true

# SimpleCov removed entirely

ENV['RAILS_ENV'] ||= 'test'
require File.expand_path('../config/environment', __dir__)
abort('The Rails environment is running in production mode!') if Rails.env.production?
require 'rspec/rails'
require 'factory_bot_rails'

# Require rails-controller-testing for Rails 8 compatibility
require 'rails-controller-testing'

# Test profiling (only load when needed to avoid overhead)
require 'test_prof' if ENV['SAMPLE'] || ENV['RPROF'] || ENV['STACKPROF'] || ENV['TAG_PROF']

# Maintain test schema with strict error handling
begin
  ActiveRecord::Migration.maintain_test_schema!
rescue ActiveRecord::PendingMigrationError => e
  puts "ERROR: Pending migrations detected: #{e.message}"
  puts 'Run `rails db:migrate` before running tests'
  exit 1
rescue ActiveRecord::ConnectionNotEstablished => e
  puts "ERROR: Database connection failed: #{e.message}"
  puts 'Ensure database is running and properly configured'
  exit 1
rescue StandardError => e
  puts "ERROR: Schema maintenance failed: #{e.message}"
  puts 'Check database configuration and migrations'
  exit 1
end

# Require support files
Dir[Rails.root.join('spec/support/**/*.rb')].sort.each { |f| require f }

# Load test effectiveness validation
require Rails.root.join('spec/support/test_effectiveness.rb')

RSpec.configure do |config|
  # Use database transactions for fast test isolation instead of expensive delete_all
  config.use_transactional_fixtures = true
  config.use_instantiated_fixtures = false

  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!

  config.include ActiveJob::TestHelper
  config.include FactoryBot::Syntax::Methods

  # Enable controller testing features for Rails 8
  Rails::Controller::Testing.install

  # Add custom formatter for clear test identification
  config.add_formatter TestNameFormatter

  # Test effectiveness validation
  config.before(:each) do |example|
    puts "\n🧪 Running: #{example.full_description}" unless ENV['TEST_ENV_NUMBER']
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
    clear_performed_jobs

    # Track original method definitions to detect mocking
    @original_methods = {}
  end

  # Validate test effectiveness after each test
  config.after(:each) do |example|
    # Check if test is using excessive mocking (more than 3 mocks suggests testing mocks, not behavior)
    mock_count = example.metadata[:mock_count] || 0
    if mock_count > 3 && !example.metadata[:integration_test]
      puts "⚠️  WARNING: Test '#{example.full_description}' uses #{mock_count} mocks. Consider integration testing."
    end
  end

  # Prevent individual test failures from causing the suite to exit
  config.fail_fast = false

  # Add safety for database operations
  config.before(:suite) do
    # Ensure database is available before starting tests
    ActiveRecord::Base.connection.execute('SELECT 1') if defined?(ActiveRecord::Base) && ActiveRecord::Base.connection
  rescue StandardError => e
    puts "ERROR: Database health check failed: #{e.message}"
    puts 'Tests cannot continue with database issues'
    exit 1
  end

  # Removed expensive delete_all operations - transactional fixtures handle cleanup
  # Individual tests can clean specific data if needed

  # Host authorization is disabled in test environment via config.hosts = nil
end
