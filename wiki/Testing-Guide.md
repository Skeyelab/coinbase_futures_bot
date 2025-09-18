# Testing Guide

## Overview

The coinbase_futures_bot maintains a comprehensive test suite with **94 test files** covering all critical functionality. The testing strategy emphasizes reliability, maintainability, and fast execution with **RSpec** as the primary testing framework.

## Testing Framework Stack

### Core Testing Tools
- **RSpec**: Primary testing framework with Rails integration
- **FactoryBot**: Test data generation and object creation
- **VCR**: HTTP interaction recording/replay for API testing
- **WebMock**: HTTP request stubbing and mocking
- **ActiveJob::TestHelper**: Background job testing utilities
- **SimpleCov**: Code coverage analysis and reporting

### Test Database
- **PostgreSQL**: Same engine as production for consistency
- **Transactional fixtures**: Fast test isolation and cleanup
- **Database cleaner**: Automatic cleanup between tests

## Test Structure

### Directory Organization
```
spec/
├── channels/                 # WebSocket channel specs
│   └── signals_channel_spec.rb
├── controllers/              # Controller specs
│   ├── api/
│   │   └── positions_controller_spec.rb
│   ├── health_controller_spec.rb
│   ├── positions_controller_spec.rb
│   ├── signal_controller_spec.rb
│   └── slack_controller_spec.rb
├── factories/                # FactoryBot factories
│   ├── candles.rb
│   ├── positions.rb
│   ├── signal_alerts.rb
│   ├── ticks.rb
│   └── trading_pairs.rb
├── fixtures/                 # Test data and VCR cassettes
│   └── vcr_cassettes/
├── jobs/                     # Background job specs
│   ├── fetch_candles_job_spec.rb
│   ├── generate_signals_job_spec.rb
│   ├── score_sentiment_job_spec.rb
│   └── aggregate_sentiment_job_spec.rb
├── lib/                      # Library and task specs
│   └── tasks/
│       ├── day_trading_spec.rb
│       └── realtime_signals_rake_spec.rb
├── models/                   # Model specs
│   ├── candle_spec.rb
│   ├── position_spec.rb
│   ├── sentiment_event_spec.rb
│   ├── signal_alert_spec.rb
│   └── trading_pair_spec.rb
├── requests/                 # API endpoint integration specs
│   ├── health_check_spec.rb
│   ├── positions_spec.rb
│   ├── sentiment_controller_spec.rb
│   └── signal_controller_spec.rb
├── services/                 # Service object specs
│   ├── coinbase/
│   │   ├── advanced_trade_client_spec.rb
│   │   └── exchange_client_spec.rb
│   ├── market_data/
│   │   ├── coinbase_rest_spec.rb
│   │   └── real_time_candle_aggregator_spec.rb
│   ├── sentiment/
│   │   ├── crypto_panic_client_spec.rb
│   │   └── simple_lexicon_scorer_spec.rb
│   ├── strategy/
│   │   └── multi_timeframe_signal_spec.rb
│   └── trading/
│       └── coinbase_positions_spec.rb
├── support/                  # Test support files
│   ├── vcr.rb               # VCR configuration
│   ├── rspec_rails.rb       # Rails test helpers
│   ├── climate_control.rb   # Environment variable helpers
│   ├── factory_helpers.rb   # FactoryBot helpers
│   └── test_env_setup.rb    # Test environment setup
├── tasks/                    # Rake task specs
│   ├── chat_bot_rake_spec.rb
│   └── market_data_rake_spec.rb
├── rails_helper.rb          # Rails-specific test configuration
└── spec_helper.rb           # Core RSpec configuration
```

## Test Configuration

### RSpec Configuration
```ruby
# spec/rails_helper.rb
require 'spec_helper'
ENV['RAILS_ENV'] ||= 'test'
require_relative '../config/environment'

abort("Rails is running in production mode!") if Rails.env.production?

require 'rspec/rails'
require 'factory_bot_rails'
require 'webmock/rspec'
require 'vcr'

# Configure database cleaner
RSpec.configure do |config|
  config.use_transactional_fixtures = true
  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!
  
  # Include FactoryBot methods
  config.include FactoryBot::Syntax::Methods
  
  # Include custom helpers
  config.include ActiveJob::TestHelper
  config.include ClimateControl::Modifier
end
```

### SimpleCov Configuration
```ruby
# spec/spec_helper.rb
if ENV['COVERAGE']
  require 'simplecov'
  require 'simplecov-json'
  require 'simplecov-cobertura'
  
  SimpleCov.start 'rails' do
    # Coverage thresholds
    minimum_coverage line: 85, branch: 75
    
    # Output formats
    formatter SimpleCov::Formatter::MultiFormatter.new([
      SimpleCov::Formatter::HTMLFormatter,
      SimpleCov::Formatter::JSONFormatter,
      SimpleCov::Formatter::CoberturaFormatter
    ])
    
    # Coverage groups
    add_group "Models", "app/models"
    add_group "Controllers", "app/controllers"
    add_group "Services", "app/services"
    add_group "Jobs", "app/jobs"
    add_group "Libraries", "lib"
    
    # Exclude from coverage
    add_filter '/spec/'
    add_filter '/config/'
    add_filter '/db/'
    add_filter '/vendor/'
    add_filter 'app/channels/application_cable'
    add_filter 'app/jobs/application_job.rb'
    add_filter 'app/mailers/application_mailer.rb'
    add_filter 'app/models/application_record.rb'
    add_filter 'app/controllers/application_controller.rb'
  end
end
```

## Testing Patterns

### 1. Model Testing

#### Basic Model Specs
```ruby
# spec/models/position_spec.rb
RSpec.describe Position, type: :model do
  describe 'validations' do
    subject { build(:position) }
    
    it { is_expected.to validate_presence_of(:product_id) }
    it { is_expected.to validate_presence_of(:side) }
    it { is_expected.to validate_inclusion_of(:side).in_array(%w[LONG SHORT]) }
    it { is_expected.to validate_numericality_of(:size).greater_than(0) }
    it { is_expected.to validate_numericality_of(:entry_price).greater_than(0) }
  end
  
  describe 'scopes' do
    let!(:open_position) { create(:position, status: 'OPEN') }
    let!(:closed_position) { create(:position, status: 'CLOSED') }
    let!(:day_trading_position) { create(:position, day_trading: true) }
    
    it 'filters open positions' do
      expect(Position.open).to contain_exactly(open_position, day_trading_position)
    end
    
    it 'filters day trading positions' do
      expect(Position.day_trading).to contain_exactly(day_trading_position)
    end
  end
  
  describe 'instance methods' do
    let(:position) { create(:position, status: 'OPEN') }
    
    describe '#open?' do
      it 'returns true for open positions' do
        expect(position.open?).to be true
      end
    end
    
    describe '#unrealized_pnl' do
      it 'calculates unrealized P&L correctly' do
        position.update!(entry_price: 100, size: 2, side: 'LONG')
        
        # Mock current price
        allow(position).to receive(:current_price).and_return(105)
        
        expect(position.unrealized_pnl).to eq(10.0)  # (105 - 100) * 2
      end
    end
  end
end
```

#### Factory Definitions
```ruby
# spec/factories/positions.rb
FactoryBot.define do
  factory :position do
    product_id { "BTC-USD" }
    side { "LONG" }
    size { 2.0 }
    entry_price { 45000.0 }
    entry_time { Time.current }
    status { "OPEN" }
    day_trading { true }
    take_profit { 45800.0 }
    stop_loss { 44500.0 }
    
    trait :short do
      side { "SHORT" }
      take_profit { 44200.0 }
      stop_loss { 45500.0 }
    end
    
    trait :closed do
      status { "CLOSED" }
      close_time { Time.current }
      pnl { 400.0 }
    end
    
    trait :swing_trading do
      day_trading { false }
    end
  end
end
```

### 2. Service Testing

#### Service Spec with Mocking
```ruby
# spec/services/strategy/multi_timeframe_signal_spec.rb
RSpec.describe Strategy::MultiTimeframeSignal do
  let(:strategy) { described_class.new }
  let(:symbol) { "BTC-USD" }
  let(:equity_usd) { 50000.0 }
  
  describe '#signal' do
    context 'with sufficient candle data' do
      before do
        # Create test candle data
        create_candles_for_symbol(symbol, timeframes: %w[1m 5m 15m 1h])
      end
      
      context 'when trend is bullish' do
        before do
          # Mock bullish trend conditions
          allow(strategy).to receive(:determine_1h_trend).and_return(:up)
          allow(strategy).to receive(:confirm_15m_trend).and_return(true)
          allow(strategy).to receive(:detect_5m_entry).and_return(true)
          allow(strategy).to receive(:confirm_1m_timing).and_return(true)
          allow(strategy).to receive(:get_sentiment_z_score).and_return(1.5)
        end
        
        it 'generates long signal' do
          signal = strategy.signal(symbol: symbol, equity_usd: equity_usd)
          
          expect(signal).to be_present
          expect(signal[:side]).to eq("long")
          expect(signal[:price]).to be > 0
          expect(signal[:quantity]).to be > 0
          expect(signal[:stop_loss]).to be < signal[:price]
          expect(signal[:take_profit]).to be > signal[:price]
        end
        
        it 'includes strategy metadata' do
          signal = strategy.signal(symbol: symbol, equity_usd: equity_usd)
          
          expect(signal[:metadata]).to include(
            trend_1h: :up,
            sentiment_z: 1.5
          )
        end
      end
      
      context 'when sentiment is neutral' do
        before do
          allow(strategy).to receive(:get_sentiment_z_score).and_return(0.5)
        end
        
        it 'returns nil (filters out signal)' do
          signal = strategy.signal(symbol: symbol, equity_usd: equity_usd)
          expect(signal).to be_nil
        end
      end
    end
    
    context 'with insufficient candle data' do
      it 'returns nil' do
        signal = strategy.signal(symbol: symbol, equity_usd: equity_usd)
        expect(signal).to be_nil
      end
    end
  end
  
  private
  
  def create_candles_for_symbol(symbol, timeframes:)
    timeframes.each do |tf|
      60.times do |i|
        create(:candle,
          symbol: symbol,
          timeframe: tf,
          timestamp: i.send(tf.gsub(/\d+/, '').to_sym).ago,
          open: 45000 + rand(-100..100),
          high: 45000 + rand(0..200),
          low: 45000 + rand(-200..0),
          close: 45000 + rand(-100..100),
          volume: rand(100..1000)
        )
      end
    end
  end
end
```

### 3. Controller Testing

#### API Controller Specs
```ruby
# spec/controllers/signal_controller_spec.rb
RSpec.describe SignalController, type: :controller do
  let(:api_key) { 'test_api_key' }
  
  before do
    ENV['SIGNALS_API_KEY'] = api_key
  end
  
  describe 'GET #index' do
    let!(:active_signal) { create(:signal_alert, alert_status: 'active', confidence: 85) }
    let!(:expired_signal) { create(:signal_alert, alert_status: 'expired') }
    
    context 'with valid API key' do
      before do
        request.headers['X-API-Key'] = api_key
      end
      
      it 'returns active signals' do
        get :index
        
        expect(response).to have_http_status(:ok)
        
        json_response = JSON.parse(response.body)
        expect(json_response['signals']).to have(1).item
        expect(json_response['signals'].first['id']).to eq(active_signal.id)
      end
      
      it 'filters by confidence' do
        get :index, params: { min_confidence: 90 }
        
        json_response = JSON.parse(response.body)
        expect(json_response['signals']).to be_empty
      end
      
      it 'paginates results' do
        get :index, params: { page: 1, per_page: 10 }
        
        json_response = JSON.parse(response.body)
        expect(json_response['meta']).to include(
          'current_page' => 1,
          'per_page' => 10
        )
      end
    end
    
    context 'without API key' do
      it 'returns unauthorized' do
        get :index
        expect(response).to have_http_status(:unauthorized)
      end
    end
  end
  
  describe 'POST #evaluate' do
    before do
      request.headers['X-API-Key'] = api_key
      request.headers['Content-Type'] = 'application/json'
    end
    
    it 'triggers signal evaluation' do
      expect(RealTimeSignalJob).to receive(:perform_later)
      
      post :evaluate, body: { symbols: ['BTC-USD'] }.to_json
      
      expect(response).to have_http_status(:ok)
      
      json_response = JSON.parse(response.body)
      expect(json_response['status']).to eq('success')
    end
  end
end
```

### 4. Job Testing

#### Background Job Specs
```ruby
# spec/jobs/generate_signals_job_spec.rb
RSpec.describe GenerateSignalsJob, type: :job do
  let(:equity_usd) { 25000.0 }
  
  describe '#perform' do
    let!(:enabled_pair) { create(:trading_pair, product_id: 'BTC-USD', enabled: true) }
    let!(:disabled_pair) { create(:trading_pair, product_id: 'ETH-USD', enabled: false) }
    
    before do
      # Create sufficient candle data
      create_list(:candle, 60, symbol: 'BTC-USD', timeframe: '1h')
      create_list(:candle, 80, symbol: 'BTC-USD', timeframe: '15m')
    end
    
    it 'processes enabled trading pairs only' do
      strategy_double = instance_double(Strategy::MultiTimeframeSignal)
      allow(Strategy::MultiTimeframeSignal).to receive(:new).and_return(strategy_double)
      
      expect(strategy_double).to receive(:signal).with(
        symbol: 'BTC-USD',
        equity_usd: equity_usd
      ).and_return(nil)
      
      # Should not process disabled pair
      expect(strategy_double).not_to receive(:signal).with(
        symbol: 'ETH-USD',
        equity_usd: anything
      )
      
      described_class.new.perform(equity_usd: equity_usd)
    end
    
    context 'when signal is generated' do
      let(:signal) do
        {
          side: 'long',
          price: 45000.0,
          quantity: 2,
          tp: 45800.0,
          sl: 44500.0,
          confidence: 85
        }
      end
      
      before do
        strategy_double = instance_double(Strategy::MultiTimeframeSignal)
        allow(Strategy::MultiTimeframeSignal).to receive(:new).and_return(strategy_double)
        allow(strategy_double).to receive(:signal).and_return(signal)
      end
      
      it 'sends Slack notification' do
        expect(SlackNotificationService).to receive(:signal_generated).with(
          hash_including(
            symbol: 'BTC-USD',
            side: 'long',
            confidence: 85
          )
        )
        
        described_class.new.perform(equity_usd: equity_usd)
      end
      
      it 'creates signal alert record' do
        expect {
          described_class.new.perform(equity_usd: equity_usd)
        }.to change(SignalAlert, :count).by(1)
        
        alert = SignalAlert.last
        expect(alert.symbol).to eq('BTC-USD')
        expect(alert.side).to eq('long')
        expect(alert.confidence).to eq(85)
      end
    end
  end
end
```

### 5. VCR Integration

#### VCR Configuration
```ruby
# spec/support/vcr.rb
VCR.configure do |config|
  config.cassette_library_dir = 'spec/fixtures/vcr_cassettes'
  config.hook_into :webmock
  config.configure_rspec_metadata!
  config.allow_http_connections_when_no_cassette = false
  
  # Filter sensitive data
  config.filter_sensitive_data('<COINBASE_API_KEY>') { ENV['COINBASE_API_KEY'] }
  config.filter_sensitive_data('<COINBASE_API_SECRET>') { ENV['COINBASE_API_SECRET'] }
  config.filter_sensitive_data('<CRYPTOPANIC_TOKEN>') { ENV['CRYPTOPANIC_TOKEN'] }
  
  # Ignore localhost requests (for test server)
  config.ignore_localhost = true
  config.ignore_hosts 'chromedriver.storage.googleapis.com'
  
  # Custom matchers for API requests
  config.default_cassette_options = {
    match_requests_on: [:method, :uri, :body],
    record: :once,
    allow_unused_http_interactions: false
  }
end
```

#### Using VCR in Tests
```ruby
# spec/services/coinbase/advanced_trade_client_spec.rb
RSpec.describe Coinbase::AdvancedTradeClient do
  let(:client) { described_class.new }
  
  describe '#get_accounts', :vcr do
    it 'retrieves account information' do
      accounts = client.get_accounts
      
      expect(accounts).to be_an(Array)
      expect(accounts.first).to include('uuid', 'name', 'currency')
    end
  end
  
  describe '#get_products', vcr: { cassette_name: 'coinbase/products' } do
    it 'retrieves product information' do
      products = client.get_products
      
      expect(products).to be_an(Array)
      expect(products.first).to include('id', 'base_currency', 'quote_currency')
    end
  end
  
  describe '#create_order', vcr: { record: :new_episodes } do
    let(:order_params) do
      {
        product_id: 'BTC-USD',
        side: 'buy',
        order_configuration: {
          limit_limit_gtc: {
            base_size: '0.001',
            limit_price: '30000.00'
          }
        }
      }
    end
    
    it 'creates a new order' do
      result = client.create_order(order_params)
      
      expect(result).to include('success')
      expect(result['order_id']).to be_present
    end
  end
end
```

### 6. Integration Testing

#### Request Specs
```ruby
# spec/requests/signal_controller_spec.rb
RSpec.describe 'Signal API', type: :request do
  let(:api_key) { 'test_api_key' }
  let(:headers) { { 'X-API-Key' => api_key } }
  
  before do
    ENV['SIGNALS_API_KEY'] = api_key
  end
  
  describe 'GET /signals' do
    let!(:btc_signal) { create(:signal_alert, symbol: 'BTC-USD', confidence: 85) }
    let!(:eth_signal) { create(:signal_alert, symbol: 'ETH-USD', confidence: 75) }
    
    it 'returns paginated signals' do
      get '/signals', headers: headers
      
      expect(response).to have_http_status(:ok)
      expect(response.content_type).to eq('application/json; charset=utf-8')
      
      json = JSON.parse(response.body)
      expect(json['signals']).to have(2).items
      expect(json['meta']).to include('total_count', 'current_page')
    end
    
    it 'filters by symbol' do
      get '/signals', params: { symbol: 'BTC-USD' }, headers: headers
      
      json = JSON.parse(response.body)
      expect(json['signals']).to have(1).item
      expect(json['signals'].first['symbol']).to eq('BTC-USD')
    end
    
    it 'filters by minimum confidence' do
      get '/signals', params: { min_confidence: 80 }, headers: headers
      
      json = JSON.parse(response.body)
      expect(json['signals']).to have(1).item
      expect(json['signals'].first['confidence']).to eq(85)
    end
  end
  
  describe 'POST /signals/evaluate' do
    it 'triggers signal evaluation' do
      expect {
        post '/signals/evaluate', 
             params: { symbols: ['BTC-USD'] }.to_json,
             headers: headers.merge('Content-Type' => 'application/json')
      }.to have_enqueued_job(RealTimeSignalJob)
      
      expect(response).to have_http_status(:ok)
    end
  end
end
```

## Test Execution

### Running Tests

#### Basic Test Execution
```bash
# Run entire test suite
bundle exec rspec

# Run specific test file
bundle exec rspec spec/services/strategy/multi_timeframe_signal_spec.rb

# Run specific test
bundle exec rspec spec/services/strategy/multi_timeframe_signal_spec.rb:25

# Run tests by tag
bundle exec rspec --tag vcr
bundle exec rspec --tag ~slow  # Exclude slow tests
```

#### Parallel Test Execution
```bash
# Run tests in parallel
bundle exec parallel_rspec

# Run with specific number of processes
bundle exec parallel_rspec -n 4

# Run specific files in parallel
bundle exec parallel_rspec spec/services/ spec/models/
```

#### Coverage Reports
```bash
# Run tests with coverage
COVERAGE=true bundle exec rspec

# View HTML coverage report
open coverage/index.html

# Generate coverage badge
COVERAGE=true bundle exec rspec && ./bin/view-coverage
```

### Test Performance

#### Fast Test Execution
```bash
# Use fast test runner (skips Rails boot for some tests)
./bin/fast_rspec spec/services/

# Super fast runner for unit tests
./bin/super_fast_rspec spec/models/

# Run only changed tests
./bin/run_tests_with_names $(git diff --name-only HEAD~1 | grep _spec.rb)
```

#### Test Profiling
```ruby
# Add to spec/rails_helper.rb
require 'test-prof/recipes/rspec/before_all'
require 'test-prof/recipes/rspec/let_it_be'

# Profile slow tests
RSpec.configure do |config|
  config.before(:suite) do
    TestProf::BeforeAll.configure do |config|
      config.before(:begin) do
        DatabaseCleaner.strategy = :transaction
        DatabaseCleaner.start
      end

      config.after(:rollback) do
        DatabaseCleaner.rollback
      end
    end
  end
end
```

## Coverage Analysis

### Current Coverage Statistics

Based on the test suite analysis:

- **Total Test Files**: 94 test files
- **Test Examples**: 141+ test examples
- **Target Coverage**: 85% line coverage, 75% branch coverage
- **Current Focus**: Critical business logic and API endpoints

### Coverage by Component

#### High Coverage Areas (>90%)
- **Models**: Core business models with validations and relationships
- **API Controllers**: REST endpoints with comprehensive request/response testing
- **Background Jobs**: Critical job processing with error handling
- **Core Services**: Trading strategy and market data services

#### Medium Coverage Areas (70-90%)
- **Supporting Services**: Utility services and helpers
- **Integration Points**: External API clients with VCR testing
- **Configuration**: Environment and setup validation

#### Areas for Improvement (<70%)
- **Error Handling Edge Cases**: Complex error scenarios
- **WebSocket Integration**: Real-time data streaming
- **Performance Edge Cases**: High-load scenarios

### Coverage Monitoring

#### CI Integration
```yaml
# .github/workflows/ci.yml (excerpt)
- name: Run Tests with Coverage
  run: |
    COVERAGE=true bundle exec rspec
    echo "Coverage report generated"
  
- name: Upload Coverage Artifacts
  uses: actions/upload-artifact@v3
  with:
    name: coverage-report
    path: coverage/
    retention-days: 30
```

#### Coverage Thresholds
```ruby
# In spec/spec_helper.rb SimpleCov configuration
SimpleCov.start 'rails' do
  # Fail build if coverage drops below thresholds
  minimum_coverage line: 85, branch: 75
  
  # Coverage decline threshold
  refuse_coverage_drop
  
  # Track coverage over time
  track_files 'app/**/*.rb'
end
```

## Testing Best Practices

### 1. Test Organization
- **Arrange-Act-Assert**: Clear test structure
- **One Assertion Per Test**: Focus on single behavior
- **Descriptive Names**: Tests should read like specifications
- **Logical Grouping**: Use `describe` and `context` blocks effectively

### 2. Test Data Management
- **Factory Usage**: Use FactoryBot for consistent test data
- **Minimal Setup**: Create only necessary data for each test
- **Realistic Data**: Use realistic values that mirror production
- **Cleanup**: Ensure tests clean up after themselves

### 3. Mocking and Stubbing
- **External Services**: Always mock external API calls
- **Time-Dependent Code**: Use `travel_to` for time-based tests
- **Database Queries**: Mock expensive queries in unit tests
- **Side Effects**: Mock operations with side effects

### 4. VCR Best Practices
- **Sensitive Data**: Filter all API keys and secrets
- **Cassette Management**: Use descriptive cassette names
- **Update Strategy**: Regularly update cassettes for API changes
- **Fallback Testing**: Test both success and failure scenarios

### 5. Performance Testing
- **Fast Unit Tests**: Keep unit tests under 100ms
- **Isolated Integration**: Use transactions for database tests
- **Parallel Execution**: Leverage parallel test runners
- **Profiling**: Identify and optimize slow tests

## Continuous Integration

### GitHub Actions Integration

The project uses GitHub Actions for automated testing:

```yaml
name: CI
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    
    services:
      postgres:
        image: postgres:14
        env:
          POSTGRES_PASSWORD: postgres
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5
    
    steps:
      - uses: actions/checkout@v3
      
      - name: Set up Ruby
        uses: ruby/setup-ruby@v1
        with:
          bundler-cache: true
          
      - name: Set up Database
        run: |
          bin/rails db:prepare
        env:
          DATABASE_URL: postgres://postgres:postgres@localhost:5432/test
          RAILS_ENV: test
          
      - name: Run Linter
        run: bin/standardrb
        
      - name: Run Security Scan
        run: bundle exec brakeman
        
      - name: Run Tests
        run: COVERAGE=true bundle exec rspec
        env:
          DATABASE_URL: postgres://postgres:postgres@localhost:5432/test
          RAILS_ENV: test
          
      - name: Upload Coverage
        uses: actions/upload-artifact@v3
        with:
          name: coverage-report
          path: coverage/
```

### Quality Gates

Tests must pass these quality gates:

1. **All Tests Pass**: 100% test success rate
2. **Code Coverage**: Minimum 85% line coverage
3. **Linting**: StandardRB compliance
4. **Security**: Brakeman security scan
5. **Performance**: No tests slower than 30 seconds

## Debugging Tests

### Common Issues

#### Flaky Tests
```ruby
# Use retry for network-dependent tests
RSpec.describe 'API Integration', retry: 3 do
  # Test code
end

# Use proper test isolation
before do
  # Reset global state
  Rails.cache.clear
  Timecop.return
end
```

#### Database State Issues
```ruby
# Use database_cleaner for complex scenarios
RSpec.configure do |config|
  config.before(:suite) do
    DatabaseCleaner.strategy = :transaction
    DatabaseCleaner.clean_with(:truncation)
  end
  
  config.around do |example|
    DatabaseCleaner.cleaning do
      example.run
    end
  end
end
```

#### Time-Dependent Tests
```ruby
# Use Timecop for consistent time testing
RSpec.describe 'Time-dependent behavior' do
  around do |example|
    travel_to(Time.zone.parse('2025-01-18 10:00:00')) do
      example.run
    end
  end
end
```

### Test Debugging Tools

```bash
# Run tests with debugging
bundle exec rspec --backtrace spec/failing_spec.rb

# Run single test with pry debugging
bundle exec rspec spec/failing_spec.rb:25 --require pry --pry

# Profile test performance
TEST_PROF=1 bundle exec rspec spec/slow_spec.rb

# Memory profiling
TEST_PROF=MEMORY bundle exec rspec spec/
```

---

**Next**: [Deployment](Deployment) | **Previous**: [Configuration](Configuration) | **Up**: [Home](Home)