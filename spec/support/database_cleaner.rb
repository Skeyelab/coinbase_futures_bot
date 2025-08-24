# Database performance optimization for tests
RSpec.configure do |config|
  # Use transaction rollback instead of truncation for speed
  config.use_transactional_fixtures = true

  # Only clean database when absolutely necessary
  config.before(:suite) do
    # Clean database once at start
    ActiveRecord::Base.connection.execute('TRUNCATE TABLE trading_pairs RESTART IDENTITY CASCADE;')
    ActiveRecord::Base.connection.execute('TRUNCATE TABLE candles RESTART IDENTITY CASCADE;')
    ActiveRecord::Base.connection.execute('TRUNCATE TABLE sentiment_events RESTART IDENTITY CASCADE;')
    ActiveRecord::Base.connection.execute('TRUNCATE TABLE sentiment_aggregates RESTART IDENTITY CASCADE;')
  end

  # Use fast truncation only for tests that need it
  config.before(:each, :database_cleanup) do
    ActiveRecord::Base.connection.execute('DELETE FROM trading_pairs;')
    ActiveRecord::Base.connection.execute('DELETE FROM candles;')
    ActiveRecord::Base.connection.execute('DELETE FROM sentiment_events;')
    ActiveRecord::Base.connection.execute('DELETE FROM sentiment_aggregates;')
  end
end
