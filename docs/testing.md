# Testing Documentation

## Overview

The coinbase_futures_bot uses RSpec as the primary testing framework with comprehensive test coverage across models, services, jobs, and API endpoints. The testing strategy emphasizes reliability, maintainability, and fast execution.

## Testing Framework Stack

### Core Testing Tools
- **RSpec**: Primary testing framework
- **RSpec-Rails**: Rails integration for RSpec
- **FactoryBot**: Test data generation (when needed)
- **VCR**: HTTP interaction recording/replay
- **WebMock**: HTTP request stubbing
- **ActiveJob::TestHelper**: Job testing utilities

### Test Database
- **PostgreSQL**: Same engine as production
- **Transactional fixtures**: Fast test isolation
- **Database cleaner**: Automatic cleanup between tests

## Test Structure

### Directory Organization
```
spec/
├── controllers/           # Controller specs
│   └── positions_controller_spec.rb
├── jobs/                 # Background job specs
│   ├── fetch_candles_job_spec.rb
│   ├── score_sentiment_job_spec.rb
│   └── aggregate_sentiment_job_spec.rb
├── models/              # Model specs
│   ├── candle_spec.rb
│   ├── trading_pair_spec.rb
│   └── sentiment_event_spec.rb
├── requests/            # API endpoint specs
│   ├── health_check_spec.rb
│   ├── positions_spec.rb
│   └── sentiment_controller_spec.rb
├── services/            # Service object specs
│   ├── coinbase_rest_spec.rb
│   ├── coinbase_positions_spec.rb
│   └── strategy/
│       └── multi_timeframe_signal_spec.rb
├── support/             # Test support files
│   ├── vcr.rb          # VCR configuration
│   ├── rspec_rails.rb  # Rails test helpers
│   └── climate_control.rb # Environment variable helpers
├── tasks/               # Rake task specs
│   └── market_data_rake_spec.rb
├── fixtures/            # Test data and VCR cassettes
│   └── vcr_cassettes/
└── rails_helper.rb      # Rails test configuration
```

## Test Configuration

### Rails Helper Configuration
```ruby
# spec/rails_helper.rb
ENV["RAILS_ENV"] ||= "test"
require File.expand_path("../config/environment", __dir__)
require "rspec/rails"

RSpec.configure do |config|
  # Use database transactions for fast test isolation
  config.use_transactional_fixtures = true
  config.use_instantiated_fixtures = false

  # Auto-detect spec types based on file location
  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!

  # Include ActiveJob test helpers
  config.include ActiveJob::TestHelper

  # Setup job testing environment
  config.before(:each) do
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
    clear_performed_jobs
  end
end
```

### VCR Configuration
```ruby
# spec/support/vcr.rb
VCR.configure do |config|
  config.cassette_library_dir = "spec/fixtures/vcr_cassettes"
  config.hook_into :webmock
  config.configure_rspec_metadata!

  # Filter sensitive data
  config.filter_sensitive_data("<COINBASE_API_KEY>") { ENV["COINBASE_API_KEY"] }
  config.filter_sensitive_data("<COINBASE_API_SECRET>") { ENV["COINBASE_API_SECRET"] }
  config.filter_sensitive_data("<TIMESTAMP>") { Time.now.to_i.to_s }

  # Ignore monitoring service requests
  config.ignore_request do |request|
    request.uri.include?("sentry.io") || request.uri.include?("glitchtip")
  end

  config.default_cassette_options = {
    record: :new_episodes,
    match_requests_on: [:method, :uri, :body]
  }
end
```

## Testing Patterns

### Model Testing

#### Basic Model Specs
```ruby
# spec/models/trading_pair_spec.rb
RSpec.describe TradingPair, type: :model do
  describe 'validations' do
    it 'validates presence and uniqueness of product_id' do
      pair = TradingPair.create!(product_id: 'BTC-USD')
      expect(pair).to be_valid

      duplicate = TradingPair.new(product_id: 'BTC-USD')
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:product_id]).to include('has already been taken')
    end
  end

  describe 'scopes' do
    let!(:active_pair) { TradingPair.create!(product_id: 'BTC-USD', enabled: true) }
    let!(:inactive_pair) { TradingPair.create!(product_id: 'ETH-USD', enabled: false) }

    it 'returns only enabled pairs' do
      expect(TradingPair.enabled).to include(active_pair)
      expect(TradingPair.enabled).not_to include(inactive_pair)
    end
  end
end
```

#### Time-dependent Testing
```ruby
# Testing with fixed dates
let(:current_date) { Date.new(2025, 8, 15) }

before do
  allow(Date).to receive(:current).and_return(current_date)
end

it 'identifies current month contracts' do
  august_contract = TradingPair.create!(
    product_id: 'BIT-29AUG25-CDE',
    expiration_date: Date.new(2025, 8, 29)
  )
  expect(august_contract.current_month?).to be true
end
```

### Job Testing

#### Background Job Specs
```ruby
# spec/jobs/fetch_candles_job_spec.rb
RSpec.describe FetchCandlesJob, type: :job do
  include ActiveJob::TestHelper

  let(:btc_pair) do
    TradingPair.find_or_create_by(product_id: "BTC-USD") do |tp|
      tp.base_currency = "BTC"
      tp.quote_currency = "USD"
      tp.enabled = true
    end
  end

  describe "#perform" do
    it "fetches candle data successfully", :vcr do
      VCR.use_cassette("fetch_candles_success") do
        expect { described_class.perform_now(backfill_days: 1) }
          .not_to raise_error

        expect(Candle.where(symbol: "BTC-USD").count).to be >= 0
      end
    end

    it "handles API errors gracefully" do
      allow_any_instance_of(MarketData::CoinbaseRest)
        .to receive(:upsert_1h_candles)
        .and_raise(StandardError, "API Error")

      expect { described_class.perform_now }.not_to raise_error
    end
  end

  describe "job enqueueing" do
    it "enqueues the job" do
      expect { described_class.perform_later(backfill_days: 7) }
        .to have_enqueued_job(described_class)
        .with(backfill_days: 7)
        .on_queue("default")
    end
  end
end
```

#### Sentiment Job Testing
```ruby
# spec/jobs/score_sentiment_job_spec.rb
RSpec.describe ScoreSentimentJob, type: :job do
  it "scores unscored events and sets confidence" do
    bullish_event = SentimentEvent.create!(
      source: "cryptopanic",
      published_at: Time.current,
      raw_text_hash: "positive_hash",
      title: "Bitcoin bullish breakout rally"
    )

    bearish_event = SentimentEvent.create!(
      source: "cryptopanic",
      published_at: Time.current,
      raw_text_hash: "negative_hash",
      title: "Bitcoin bearish crash dump"
    )

    described_class.perform_now

    bullish_event.reload
    bearish_event.reload

    expect(bullish_event.score).to be_between(-1, 1)
    expect(bullish_event.confidence).to be_between(0, 1)
    expect(bearish_event.score).to be_between(-1, 1)
    expect(bearish_event.confidence).to be_between(0, 1)
  end
end
```

### Service Testing

#### Service Object Specs
```ruby
# spec/services/coinbase_rest_spec.rb
RSpec.describe MarketData::CoinbaseRest do
  let(:service) { described_class.new }

  describe "#upsert_products" do
    it "fetches and stores product data", :vcr do
      VCR.use_cassette("coinbase_products") do
        expect { service.upsert_products }
          .to change { TradingPair.count }
      end
    end
  end

  describe "#upsert_1h_candles" do
    let(:btc_pair) { TradingPair.create!(product_id: "BTC-USD") }

    it "fetches and stores candle data", :vcr do
      VCR.use_cassette("coinbase_1h_candles") do
        service.upsert_1h_candles(
          product_id: btc_pair.product_id,
          start_time: 24.hours.ago,
          end_time: Time.current
        )

        expect(Candle.where(symbol: btc_pair.product_id, timeframe: "1h"))
          .to exist
      end
    end
  end
end
```

#### Strategy Testing
```ruby
# spec/services/strategy/multi_timeframe_signal_spec.rb
RSpec.describe Strategy::MultiTimeframeSignal do
  let(:strategy) { described_class.new }

  describe "#signal" do
    let(:btc_pair) { TradingPair.create!(product_id: "BTC-USD-PERP") }

    before do
      # Create test candle data
      create_candle_data("BTC-USD-PERP", "1h", 100)
      create_candle_data("BTC-USD-PERP", "15m", 200)
    end

    it "generates valid signals" do
      signal = strategy.signal(symbol: "BTC-USD-PERP", equity_usd: 10_000)

      if signal
        expect(signal).to include(:side, :price, :quantity, :tp, :sl, :confidence)
        expect(signal[:side]).to be_in(["long", "short"])
        expect(signal[:quantity]).to be > 0
        expect(signal[:confidence]).to be_between(0, 100)
      end
    end

    it "handles insufficient data gracefully" do
      Candle.delete_all
      signal = strategy.signal(symbol: "BTC-USD-PERP", equity_usd: 10_000)
      expect(signal).to be_nil
    end
  end

  def create_candle_data(symbol, timeframe, count)
    count.times do |i|
      Candle.create!(
        symbol: symbol,
        timeframe: timeframe,
        timestamp: i.hours.ago,
        open: 50000 + rand(1000),
        high: 50500 + rand(1000),
        low: 49500 + rand(1000),
        close: 50000 + rand(1000),
        volume: rand(100)
      )
    end
  end
end
```

### API Testing

#### Request Specs
```ruby
# spec/requests/sentiment_controller_spec.rb
RSpec.describe "Sentiment API", type: :request do
  describe "GET /sentiment/aggregates" do
    let!(:btc_aggregate) do
      SentimentAggregate.create!(
        symbol: "BTC-USD-PERP",
        window: "15m",
        window_end_at: Time.current,
        count: 5,
        avg_score: 0.25,
        z_score: 1.5
      )
    end

    it "returns sentiment aggregates" do
      get "/sentiment/aggregates", params: { symbol: "BTC-USD-PERP", limit: 10 }

      expect(response).to have_http_status(:ok)
      json_response = JSON.parse(response.body)
      expect(json_response).to be_an(Array)
      expect(json_response.first["symbol"]).to eq("BTC-USD-PERP")
    end

    it "filters by window parameter" do
      get "/sentiment/aggregates", params: { window: "15m" }

      expect(response).to have_http_status(:ok)
      json_response = JSON.parse(response.body)
      json_response.each do |aggregate|
        expect(aggregate["window"]).to eq("15m")
      end
    end
  end
end
```

#### Health Check Testing
```ruby
# spec/requests/health_check_spec.rb
RSpec.describe "Health Check", type: :request do
  describe "GET /up" do
    it "returns 200 when application is healthy" do
      get "/up"
      expect(response).to have_http_status(:ok)
    end
  end
end
```

### Controller Testing

#### Position Controller Specs
```ruby
# spec/controllers/positions_controller_spec.rb
RSpec.describe PositionsController, type: :controller do
  describe "GET #index" do
    it "renders successfully" do
      get :index
      expect(response).to be_successful
      expect(response).to render_template(:index)
    end
  end

  describe "POST #create" do
    let(:valid_params) { { product_id: "BTC-USD-PERP" } }

    it "creates a new position with valid parameters" do
      expect { post :create, params: valid_params }
        .to change { Position.count }.by(1)
      expect(response).to redirect_to(positions_path)
    end
  end
end
```

## Advanced Testing Techniques

### VCR Usage Patterns

#### Recording New Cassettes
```ruby
# Record interactions with real API
it "fetches market data", vcr: { record: :new_episodes } do
  service.fetch_market_data
end

# Re-record existing cassette
it "updates market data", vcr: { record: :all } do
  service.update_market_data
end
```

#### Sensitive Data Filtering
```ruby
# Filter API keys and secrets
VCR.configure do |config|
  config.filter_sensitive_data("<API_KEY>") { ENV["COINBASE_API_KEY"] }
  config.filter_sensitive_data("<SECRET>") { ENV["COINBASE_API_SECRET"] }

  # Filter dynamic timestamps
  config.filter_sensitive_data("<TIMESTAMP>") do |interaction|
    Time.parse(interaction.response.body.match(/"timestamp":"([^"]+)"/)[1]).to_i.to_s
  rescue
    "<TIMESTAMP>"
  end
end
```

### Mocking and Stubbing

#### External Service Mocking
```ruby
# Mock Coinbase API responses
before do
  allow_any_instance_of(Coinbase::AdvancedTradeClient)
    .to receive(:list_futures_positions)
    .and_return([
      { "product_id" => "BTC-USD-PERP", "size" => "0.1" }
    ])
end
```

#### Time Mocking
```ruby
# Use Timecop for time-dependent tests
require 'timecop'

it "processes data for specific time" do
  Timecop.freeze(Time.parse("2025-01-15 10:00:00 UTC")) do
    service.process_data
    expect(result.timestamp).to eq(Time.parse("2025-01-15 10:00:00 UTC"))
  end
end
```

### Environment Variable Testing

#### Climate Control Usage
```ruby
# spec/support/climate_control.rb
require 'climate_control'

RSpec.configure do |config|
  config.include ClimateControl::RspecMatchers
end

# In tests
it "uses configured threshold" do
  with_environment("SENTIMENT_Z_THRESHOLD" => "2.0") do
    expect(strategy.sentiment_threshold).to eq(2.0)
  end
end
```

## Test Data Management

### Database Setup
```ruby
# Use transactional fixtures for speed
RSpec.configure do |config|
  config.use_transactional_fixtures = true

  # Clean specific data when needed
  config.before(:each, :clean_candles) do
    Candle.delete_all
  end
end
```

### Factory Patterns (when needed)
```ruby
# Create test data with specific attributes
def create_trading_pair(overrides = {})
  defaults = {
    product_id: "BTC-USD-PERP",
    base_currency: "BTC",
    quote_currency: "USD",
    enabled: true
  }
  TradingPair.create!(defaults.merge(overrides))
end
```

## Testing Best Practices

### Test Organization
1. **Group related tests**: Use `describe` and `context` blocks
2. **Clear test names**: Describe expected behavior
3. **One assertion per test**: Focus on single behavior
4. **Use let blocks**: For lazy-loaded test data

### Performance Optimization
1. **Use transactional fixtures**: Faster than database cleaning
2. **Mock external services**: Avoid real API calls
3. **Minimal test data**: Create only what's needed
4. **Parallel testing**: Run tests in parallel when possible

### Error Testing
```ruby
it "handles API timeout errors" do
  allow(service).to receive(:api_call).and_raise(Timeout::Error)

  expect { service.fetch_data }
    .not_to raise_error

  expect(service.last_error).to be_a(Timeout::Error)
end
```

## Running Tests

### Basic Commands
```bash
# Run all tests
bundle exec rspec

# Run specific test file
bundle exec rspec spec/models/trading_pair_spec.rb

# Run specific test
bundle exec rspec spec/models/trading_pair_spec.rb:25

# Run tests with specific tag
bundle exec rspec --tag vcr

# Run tests excluding tag
bundle exec rspec --tag ~slow
```

### Test Filtering
```bash
# Run only model tests
bundle exec rspec spec/models/

# Run only failing tests
bundle exec rspec --only-failures

# Run tests matching pattern
bundle exec rspec --grep "candle"
```

### Coverage and Reporting
```bash
# Run with coverage (if SimpleCov configured)
COVERAGE=true bundle exec rspec

# Generate HTML coverage report
bundle exec rspec --format html --out coverage/index.html

# Verbose output
bundle exec rspec --format documentation
```

## Continuous Integration

### GitHub Actions Integration
```yaml
# .github/workflows/test.yml
name: Test

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest

    services:
      postgres:
        image: postgres:13
        env:
          POSTGRES_PASSWORD: password
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

      - name: Setup database
        run: |
          bundle exec rails db:create
          bundle exec rails db:migrate
        env:
          DATABASE_URL: postgres://postgres:password@localhost:5432/test

      - name: Run tests
        run: bundle exec rspec
        env:
          DATABASE_URL: postgres://postgres:password@localhost:5432/test
          RAILS_ENV: test
```

## Troubleshooting Tests

### Common Issues

#### 1. VCR Cassette Errors
```bash
# Re-record cassettes
rm -rf spec/fixtures/vcr_cassettes/
bundle exec rspec  # Will record new cassettes
```

#### 2. Database State Issues
```bash
# Reset test database
RAILS_ENV=test bundle exec rails db:drop db:create db:migrate
```

#### 3. Time-dependent Test Failures
```ruby
# Use consistent time in tests
before do
  allow(Time).to receive(:current).and_return(Time.parse("2025-01-15 10:00:00 UTC"))
end
```

#### 4. Job Testing Issues
```ruby
# Ensure clean job state
before do
  clear_enqueued_jobs
  clear_performed_jobs
end
```

### Debug Strategies

#### Verbose Logging
```ruby
# Enable verbose logging in tests
Rails.logger.level = Logger::DEBUG

# Add debug output
puts "Current candles: #{Candle.count}"
puts "Response body: #{response.body}"
```

#### Interactive Debugging
```ruby
# Add pry breakpoints
require 'pry'
binding.pry

# In test
it "debugs the issue" do
  service.call
  binding.pry  # Pause execution here
  expect(result).to be_truthy
end
```

## Test Coverage Goals

### Current Coverage Areas
- **Models**: Validations, scopes, methods
- **Services**: Core business logic, error handling
- **Jobs**: Background processing, scheduling
- **Controllers**: API endpoints, request handling
- **Integration**: End-to-end workflows

### Coverage Targets
- **Unit Tests**: >90% line coverage
- **Integration Tests**: Critical user flows
- **API Tests**: All public endpoints
- **Error Scenarios**: Exception handling paths

### Monitoring Coverage
```ruby
# Add SimpleCov (in Gemfile development group)
gem 'simplecov', require: false

# In spec_helper.rb
if ENV['COVERAGE']
  require 'simplecov'
  SimpleCov.start 'rails'
end
```

Run tests with coverage:
```bash
COVERAGE=true bundle exec rspec
open coverage/index.html
```
