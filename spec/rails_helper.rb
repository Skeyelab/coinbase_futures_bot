# frozen_string_literal: true

# SimpleCov removed entirely

ENV["RAILS_ENV"] ||= "test"
require File.expand_path("../config/environment", __dir__)
abort("The Rails environment is running in production mode!") if Rails.env.production?
require "rspec/rails"
require "factory_bot_rails"

# Require rails-controller-testing for Rails 8 compatibility
require "rails-controller-testing"

# Test profiling (only load when needed to avoid overhead)
will_load_test_prof = (ENV["SAMPLE"] && ENV["SAMPLE"] != "") || (ENV["RPROF"] && ENV["RPROF"] != "") || (ENV["STACKPROF"] && ENV["STACKPROF"] != "") || (ENV["TAG_PROF"] && ENV["TAG_PROF"] != "")

if ENV["RSPEC_DEBUG"] == "1"
  puts "=== TestProf DEBUG ==="
  puts "TAG_PROF env var: '#{ENV["TAG_PROF"]}'"
  puts "SAMPLE env var: '#{ENV["SAMPLE"]}'"
  puts "RPROF env var: '#{ENV["RPROF"]}'"
  puts "STACKPROF env var: '#{ENV["STACKPROF"]}'"
  puts "Will load TestProf: #{will_load_test_prof}"
end

if will_load_test_prof
  require "test_prof"
  puts "TestProf loaded successfully" if ENV["RSPEC_DEBUG"] == "1"
elsif ENV["RSPEC_DEBUG"] == "1"
  puts "TestProf NOT loaded (environment variables empty)"
end

# CI-specific configuration and verification (opt-in; keeps local/CI logs quiet)
if ENV["CI"] && ENV["RSPEC_DEBUG"] == "1"
  puts "=== CI ENVIRONMENT DETECTED ==="
  puts "Forcing real test execution..."
  puts "Rails environment: #{Rails.env}"
  puts "Database URL: #{ENV["DATABASE_URL"]}"

  # Debug database connection pooling
  puts "=== DATABASE DEBUG ==="
  if ActiveRecord::Base.connected?
    puts "Database connected: #{ActiveRecord::Base.connection.current_database}"
    puts "Connection pool size: #{ActiveRecord::Base.connection_pool.size}"
    puts "Connection pool connections: #{ActiveRecord::Base.connection_pool.connections.size}"
  end

  # Debug Rails cache status
  puts "=== RAILS CACHE DEBUG ==="
  puts "Rails cache store: #{Rails.cache.class.name}"
  puts "Rails cache enabled: #{Rails.cache.respond_to?(:enabled?) ? Rails.cache.enabled? : "unknown"}"

  # Debug FactoryBot status
  puts "=== FACTORYBOT DEBUG ==="
  puts "FactoryBot defined: #{defined?(FactoryBot)}"
  puts "FactoryBot factories count: #{FactoryBot.factories.count}" if defined?(FactoryBot)

  # Debug if any parallel processing is happening
  puts "=== PROCESS DEBUG ==="
  puts "Ruby process ID: #{Process.pid}"

  puts "Test effectiveness module loaded: #{defined?(TestEffectiveness)}"
end

# Maintain test schema with strict error handling
begin
  ActiveRecord::Migration.maintain_test_schema!
rescue ActiveRecord::PendingMigrationError => e
  puts "ERROR: Pending migrations detected: #{e.message}"
  puts "Run `rails db:migrate` before running tests"
  exit 1
rescue ActiveRecord::ConnectionNotEstablished => e
  puts "ERROR: Database connection failed: #{e.message}"
  puts "Ensure database is running and properly configured"
  exit 1
rescue => e
  puts "ERROR: Schema maintenance failed: #{e.message}"
  puts "Check database configuration and migrations"
  exit 1
end

# Require support files
Dir[Rails.root.join("spec/support/**/*.rb")].sort.each { |f| require f }

# Load test effectiveness validation
require Rails.root.join("spec/support/test_effectiveness.rb")

RSpec.configure do |config|
  # Enable --only-failures support
  config.example_status_persistence_file_path = "spec/examples.txt"

  # Use database transactions for fast test isolation instead of expensive delete_all
  config.use_transactional_fixtures = true
  config.use_instantiated_fixtures = false

  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!

  config.include ActiveJob::TestHelper
  config.include FactoryBot::Syntax::Methods
  config.include ActiveSupport::Testing::TimeHelpers

  # Enable controller testing features for Rails 8
  Rails::Controller::Testing.install

  # Per-example narrative formatter (very noisy; opt-in only)
  config.add_formatter TestNameFormatter if ENV["VERBOSE_TESTS"] == "true"

  # Test effectiveness validation
  config.before(:each) do |example|
    if ENV["VERBOSE_TESTS"] == "true" && !ENV["TEST_ENV_NUMBER"]
      puts "\n🧪 Running: #{example.full_description}"
    end
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
    if ENV["VERBOSE_TESTS"] == "true" && mock_count > 3 && !example.metadata[:integration_test]
      puts "⚠️  WARNING: Test '#{example.full_description}' uses #{mock_count} mocks. Consider integration testing."
    end
  end

  # Prevent individual test failures from causing the suite to exit
  config.fail_fast = false

  # Add safety for database operations
  config.before(:suite) do
    # Ensure database is available before starting tests
    ActiveRecord::Base.connection.execute("SELECT 1") if defined?(ActiveRecord::Base) && ActiveRecord::Base.connection
  rescue => e
    puts "ERROR: Database health check failed: #{e.message}"
    puts "Tests cannot continue with database issues"
    exit 1
  end

  # Removed expensive delete_all operations - transactional fixtures handle cleanup
  # Individual tests can clean specific data if needed

  # Host authorization is disabled in test environment via config.hosts = nil
end

# Load test support files
Dir[Rails.root.join("spec", "support", "**", "*.rb")].each { |f| require f }
