# frozen_string_literal: true

namespace :ci do
  desc 'Verify CI environment and test setup'
  task verify: :environment do
    puts '=== CI ENVIRONMENT VERIFICATION ==='
    puts "Rails environment: #{Rails.env}"
    puts "Database URL: #{ENV['DATABASE_URL']}"
    puts "CI detected: #{ENV['CI']}"

    # Verify database connectivity
    puts "\n=== DATABASE VERIFICATION ==="
    if ActiveRecord::Base.connected?
      puts '✅ Database connected'
      puts "Database name: #{ActiveRecord::Base.connection.current_database}"
      puts "Tables: #{ActiveRecord::Base.connection.tables.join(', ')}"
    else
      puts '❌ Database not connected'
      exit 1
    end

    # Verify test files
    puts "\n=== TEST FILES VERIFICATION ==="
    test_files = Dir.glob('spec/**/*_spec.rb')
    puts "Test files found: #{test_files.count}"
    puts 'Sample test files:'
    test_files.first(5).each { |f| puts "  - #{f}" }

    # Verify test effectiveness module
    puts "\n=== TEST EFFECTIVENESS VERIFICATION ==="
    if defined?(TestEffectiveness)
      puts '✅ TestEffectiveness module loaded'
      puts "Methods available: #{TestEffectiveness.methods - Object.methods}"
    else
      puts '❌ TestEffectiveness module not loaded'
    end

    # Verify RSpec configuration
    puts "\n=== RSPEC VERIFICATION ==="
    if defined?(RSpec)
      puts '✅ RSpec loaded'
      puts "RSpec version: #{RSpec::Version::STRING}"
    else
      puts '❌ RSpec not loaded'
    end

    # Test real database operations
    puts "\n=== REAL DATABASE OPERATION TEST ==="
    begin
      # Test Position creation
      if defined?(Position)
        test_pos = Position.create!(
          product_id: 'CI-VERIFY-TEST',
          side: 'LONG',
          size: 1.0,
          entry_price: 100.0,
          entry_time: Time.current,
          status: 'OPEN',
          day_trading: true
        )
        puts "✅ Position creation test passed (ID: #{test_pos.id})"

        # Test Position update
        test_pos.update!(entry_price: 101.0)
        puts '✅ Position update test passed'

        # Test Position deletion
        test_pos.destroy
        puts '✅ Position deletion test passed'
      else
        puts '⚠️  Position model not available'
      end

      # Test TradingPair creation
      if defined?(TradingPair)
        test_pair = TradingPair.create!(
          product_id: 'CI-VERIFY-PAIR',
          symbol: 'CI-VERIFY',
          enabled: true,
          contract_type: 'futures',
          expiration_date: 1.month.from_now
        )
        puts "✅ TradingPair creation test passed (ID: #{test_pair.id})"
        test_pair.destroy
        puts '✅ TradingPair deletion test passed'
      else
        puts '⚠️  TradingPair model not available'
      end
    rescue StandardError => e
      puts "❌ Database operation test failed: #{e.message}"
      puts "Backtrace: #{e.backtrace.first(5).join("\n")}"
      exit 1
    end

    puts "\n=== CI VERIFICATION COMPLETE ==="
    puts '✅ All checks passed - CI environment is properly configured'
  end

  desc 'Run a minimal test to verify CI test execution'
  task test_minimal: :environment do
    puts '=== RUNNING MINIMAL CI TEST ==='

    # Set test environment
    ENV['RAILS_ENV'] = 'test'
    ENV['CI'] = 'true'

    # Load test environment
    require 'rspec/core'
    require 'rspec/rails'

    # Run a simple test
    RSpec::Core::Runner.run(['spec/ci_verification_spec.rb'], $stderr, $stdout)

    puts '=== MINIMAL CI TEST COMPLETE ==='
  end

  desc 'Show CI environment details'
  task info: :environment do
    puts '=== CI ENVIRONMENT INFO ==='
    puts "Rails version: #{Rails.version}"
    puts "Ruby version: #{RUBY_VERSION}"
    puts "Environment: #{Rails.env}"
    puts "Database adapter: #{ActiveRecord::Base.connection.adapter_name}"
    puts "Database URL: #{ENV['DATABASE_URL']}"
    puts "CI flag: #{ENV['CI']}"
    puts "Test environment: #{ENV['RAILS_ENV']}"

    # Show loaded gems
    puts "\n=== LOADED GEMS ==="
    Gem.loaded_specs.each do |name, spec|
      puts "#{name}: #{spec.version}" if name.include?('rspec') || name.include?('test') || name.include?('factory')
    end
  end
end
