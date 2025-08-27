# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"
require File.expand_path("../config/environment", __dir__)
abort("The Rails environment is running in production mode!") if Rails.env.production?
require "rspec/rails"
require "factory_bot_rails"

# Maintain test schema with better error handling
begin
  ActiveRecord::Migration.maintain_test_schema!
rescue ActiveRecord::PendingMigrationError => e
  puts "Warning: Pending migrations detected: #{e.message}"
  puts "Tests will continue but may have unexpected behavior"
rescue ActiveRecord::ConnectionNotEstablished => e
  puts "Warning: Database connection failed: #{e.message}"
  puts "Tests will continue but may have unexpected behavior"
rescue => e
  puts "Warning: Schema maintenance failed: #{e.message}"
  puts "Tests will continue but may have unexpected behavior"
end

# Require support files
Dir[Rails.root.join("spec/support/**/*.rb")].sort.each { |f| require f }

RSpec.configure do |config|
  # Use database transactions for fast test isolation instead of expensive delete_all
  config.use_transactional_fixtures = true
  config.use_instantiated_fixtures = false

  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!

  config.include ActiveJob::TestHelper
  config.include FactoryBot::Syntax::Methods

  # Add custom formatter for clear test identification
  config.add_formatter TestNameFormatter

  # Show test names clearly before they run
  config.before(:each) do |example|
    puts "\n🧪 Running: #{example.full_description}"
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
    clear_performed_jobs
  end

  # Prevent individual test failures from causing the suite to exit
  config.fail_fast = false

  # Add safety for database operations
  config.before(:suite) do
    # Ensure database is available before starting tests
    ActiveRecord::Base.connection.execute("SELECT 1") if defined?(ActiveRecord::Base) && ActiveRecord::Base.connection
  rescue => e
    puts "Warning: Database health check failed: #{e.message}"
    puts "Tests will continue but may have database-related issues"
  end

  # Removed expensive delete_all operations - transactional fixtures handle cleanup
  # Individual tests can clean specific data if needed
end
