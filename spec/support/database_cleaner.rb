# Database performance optimization for tests
RSpec.configure do |config|
  # Use transaction rollback instead of truncation for speed
  config.use_transactional_fixtures = true

  # Only clean database when absolutely necessary
  config.before(:suite) do
    # Check if database connection is available
    if ActiveRecord::Base.connection.active?
      # Clean database once at start - only if tables exist
      if ActiveRecord::Base.connection.table_exists?('trading_pairs')
        ActiveRecord::Base.connection.execute('TRUNCATE TABLE trading_pairs RESTART IDENTITY CASCADE;')
      end
      if ActiveRecord::Base.connection.table_exists?('candles')
        ActiveRecord::Base.connection.execute('TRUNCATE TABLE candles RESTART IDENTITY CASCADE;')
      end
      if ActiveRecord::Base.connection.table_exists?('sentiment_events')
        ActiveRecord::Base.connection.execute('TRUNCATE TABLE sentiment_events RESTART IDENTITY CASCADE;')
      end
      if ActiveRecord::Base.connection.table_exists?('sentiment_aggregates')
        ActiveRecord::Base.connection.execute('TRUNCATE TABLE sentiment_aggregates RESTART IDENTITY CASCADE;')
      end
    end
  rescue StandardError => e
    # Log the error but don't abort the test suite
    puts "Warning: Database cleanup failed: #{e.message}"
    puts 'Tests will continue with existing data'
  end

  # Use fast truncation only for tests that need it
  config.before(:each, :database_cleanup) do
    if ActiveRecord::Base.connection.active?
      if ActiveRecord::Base.connection.table_exists?('trading_pairs')
        ActiveRecord::Base.connection.execute('DELETE FROM trading_pairs;')
      end
      if ActiveRecord::Base.connection.table_exists?('candles')
        ActiveRecord::Base.connection.execute('DELETE FROM candles;')
      end
      if ActiveRecord::Base.connection.table_exists?('sentiment_events')
        ActiveRecord::Base.connection.execute('DELETE FROM sentiment_events;')
      end
      if ActiveRecord::Base.connection.table_exists?('sentiment_aggregates')
        ActiveRecord::Base.connection.execute('DELETE FROM sentiment_aggregates;')
      end
    end
  rescue StandardError => e
    puts "Warning: Per-test database cleanup failed: #{e.message}"
  end
end
