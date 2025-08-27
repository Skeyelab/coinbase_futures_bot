# Test Suite Performance Improvements

## Current Issues
- Test suite is slow (2+ minutes for ~226 examples)
- Database cleanup on every test (5 table deletes per test)
- Extensive mock data creation in some tests
- Sequential test execution

## Immediate Improvements (Easy Wins)

### 1. Database Transaction Rollback Instead of Delete
Replace the expensive `delete_all` operations with database transactions:

```ruby
# In spec/rails_helper.rb - REPLACE the current before(:each) block:
config.before(:each) do
  ActiveJob::Base.queue_adapter = :test
  clear_enqueued_jobs
  clear_performed_jobs
end

# REMOVE this expensive block:
config.before(:each) do
  begin
    Candle.delete_all
    TradingPair.delete_all
    Tick.delete_all
    SentimentEvent.delete_all
    SentimentAggregate.delete_all
  rescue ActiveRecord::StatementInvalid
    # If tables are missing in a particular environment, ignore
  end
end

# ADD this instead (database transactions are much faster):
config.use_transactional_fixtures = true
config.use_instantiated_fixtures = false

# Only clean specific data when needed in individual tests
```

### 2. Parallel Test Execution
Add the `parallel_tests` gem to run tests in parallel:

```ruby
# In Gemfile (test group):
gem 'parallel_tests', group: :test
```

Then run tests with:
```bash
bundle exec rspec spec/
```

### 3. Optimize Slow Test Files

**spec/services/strategy/multi_timeframe_signal_spec.rb** - This test creates 360+ mock candles:
```ruby
# Instead of creating 360 individual candle records, use:
let(:mock_candles) { build_list(:candle, 100) }  # Use factories
# Or mock the queries entirely:
allow(Candle).to receive(:where).and_return(mock_relation)
```

**spec/services/market_data/futures_contract_manager_spec.rb** - Optimize date mocking:
```ruby
# Use shared contexts for common date setups:
shared_context "august 2025" do
  let(:current_date) { Date.new(2025, 8, 15) }
  before { allow(Date).to receive(:current).and_return(current_date) }
end
```

### 4. Test Grouping and Tags
Tag slow tests and run them separately:

```ruby
# Tag integration tests:
RSpec.describe "Slow Integration", :slow do
  # ...
end

# Run fast tests only:
bundle exec rspec --tag ~slow

# Run all tests:
bundle exec rspec
```

### 5. Factory Bot Optimization
Use `build` instead of `create` where possible:

```ruby
# Faster (no database hit):
let(:trading_pair) { build(:trading_pair) }

# Slower (database insert):
let(:trading_pair) { create(:trading_pair) }
```

## Medium-Term Improvements

### 6. Test Database Optimization
```yaml
# config/database.yml - test section
test:
  adapter: postgresql
  # Use in-memory or faster storage for tests
  # Consider separate test database on SSD
```

### 7. Mock External Services
Replace VCR cassettes with lightweight mocks for unit tests:
```ruby
# Instead of VCR for unit tests:
allow(Faraday).to receive(:get).and_return(mock_response)
```

### 8. Selective Test Running
```bash
# Run only specific test types:
bundle exec rspec spec/models/     # Fast unit tests
bundle exec rspec spec/services/   # Service tests
bundle exec rspec spec/requests/   # Integration tests
```

## Expected Performance Gains

- **Database cleanup fix**: 50-70% speed improvement
- **Parallel execution**: 2-4x speed improvement (depending on CPU cores)
- **Mock optimization**: 20-30% additional improvement
- **Overall target**: <30 seconds for full test suite

## Implementation Priority

1. ✅ **Database cleanup fix** (immediate, huge impact)
2. ✅ **Parallel tests setup** (easy, big impact)
3. ✅ **Optimize candle creation tests** (medium effort, good impact)
4. ✅ **Add test tags** (easy, allows selective running)
5. ✅ **Factory optimizations** (ongoing, incremental)

## Quick Test Performance Check
```bash
# Before optimizations:
time bundle exec rspec

# After each optimization:
time bundle exec rspec
```
