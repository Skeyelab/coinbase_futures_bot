# Development Guide

## Overview

This guide covers the development workflow, setup instructions, and best practices for working on the coinbase_futures_bot project.

## Prerequisites

### System Requirements
- **Ruby**: 3.2.4 (managed via RVM)
- **PostgreSQL**: 13+ (local or remote)
- **Git**: Latest version
- **RVM**: Ruby Version Manager

### Development Tools
- **Code Editor**: VS Code, RubyMine, or similar
- **Database Client**: pgAdmin, TablePlus, or psql
- **API Testing**: Postman, curl, or HTTPie

## Initial Setup

### 1. Clone Repository
```bash
git clone git@github.com:Skeyelab/coinbase_futures_bot.git
cd coinbase_futures_bot
```

### 2. Ruby Environment Setup
```bash
# Install Ruby version and create gemset
rvm use ruby-3.2.4@coinbase_futures_bot --create

# Install dependencies
bundle install
```

### 3. Database Setup
```bash
# Create and setup database
bin/rails db:prepare

# Run migrations
bin/rails db:migrate

# Seed data (if available)
bin/rails db:seed
```

### 4. Environment Configuration
```bash
# Copy example environment file
cp .env.example .env

# Edit configuration
vim .env
```

**Required Environment Variables:**
```bash
DATABASE_URL=postgresql://localhost:5432/coinbase_futures_bot_development
COINBASE_API_KEY=your_development_api_key
COINBASE_API_SECRET=your_development_secret
CRYPTOPANIC_TOKEN=your_cryptopanic_token
```

### 5. Verify Setup
```bash
# Run tests to verify everything works
bundle exec rspec

# Start development server
bin/rails server

# Check health endpoint
curl http://localhost:3000/up
```

## Development Workflow

### Branch Strategy

The project follows GitHub Flow with feature branches:

```bash
# Create feature branch from main
git checkout main
git pull origin main
git checkout -b feature/your-feature-name

# Work on feature...
git add .
git commit -m "feat: implement your feature"

# Push and create PR
git push origin feature/your-feature-name
```

**Branch Naming Convention:**
- `feature/description` - New features
- `fix/description` - Bug fixes
- `docs/description` - Documentation updates
- `refactor/description` - Code improvements
- `test/description` - Test additions

### Commit Message Format

Follow Conventional Commits:

```bash
# Format: type(scope): description
feat(trading): add position size calculation
fix(api): handle rate limiting errors
docs(readme): update setup instructions
test(jobs): add sentiment job tests
refactor(services): extract common patterns
```

**Types:**
- `feat` - New features
- `fix` - Bug fixes
- `docs` - Documentation
- `test` - Tests
- `refactor` - Code improvements
- `perf` - Performance improvements
- `ci` - CI/CD changes

### Development Commands

#### Server Management
```bash
# Start development server
bin/rails server

# Start with specific port
bin/rails server -p 3001

# Start in background
bin/rails server -d

# Stop background server
kill $(cat tmp/pids/server.pid)
```

#### Database Management
```bash
# Reset database
bin/rails db:drop db:create db:migrate

# Run specific migration
bin/rails db:migrate:up VERSION=20250101000000

# Rollback last migration
bin/rails db:rollback

# Check migration status
bin/rails db:migrate:status
```

#### Job Management
```bash
# View GoodJob dashboard
open http://localhost:3000/good_job

# Run specific job
bin/rails console
FetchCandlesJob.perform_now(backfill_days: 1)

# Clear failed jobs
GoodJob::Job.where.not(error: nil).delete_all
```

#### Market Data Commands
```bash
# Subscribe to market data
bin/rake market_data:subscribe[BTC-USD-PERP]

# Backfill candle data
bin/rake market_data:backfill_candles[7]

# Test spot market subscription
INLINE=1 bin/rake "market_data:subscribe_spot[BTC-USD]"
```

#### Paper Trading
```bash
# Run one step of paper trading
bin/rake paper:step

# Generate trading signals
bin/rake signals:generate
```

## Code Style and Standards

### Ruby Style Guide

Follow RuboCop configuration in `.rubocop.yml`:

```bash
# Run style checks
bin/rubocop

# Auto-fix style issues
bin/rubocop -A

# Check specific files
bin/rubocop app/services/
```

### Code Organization

#### Service Objects
```ruby
# app/services/namespace/service_name.rb
module Namespace
  class ServiceName
    def initialize(logger: Rails.logger, **options)
      @logger = logger
      @options = options
    end

    def call
      # Main service logic
    end

    private

    def helper_method
      # Private implementation
    end
  end
end
```

#### Job Classes
```ruby
# app/jobs/job_name.rb
class JobName < ApplicationJob
  queue_as :default
  retry_on StandardError, wait: :exponentially_longer, attempts: 3

  def perform(*args)
    # Job implementation
  end
end
```

#### Model Patterns
```ruby
# app/models/model_name.rb
class ModelName < ApplicationRecord
  # Validations first
  validates :field, presence: true

  # Associations
  belongs_to :other_model

  # Scopes
  scope :active, -> { where(active: true) }

  # Class methods
  def self.method_name
    # Implementation
  end

  # Instance methods
  def instance_method
    # Implementation
  end
end
```

### Testing Standards

#### Test File Organization
```
spec/
├── controllers/
├── jobs/
├── models/
├── requests/
├── services/
├── support/
│   ├── shared_examples/
│   └── helpers/
└── system/
```

#### RSpec Patterns
```ruby
RSpec.describe ClassName do
  describe '#method_name' do
    let(:instance) { described_class.new }

    context 'when condition is met' do
      it 'performs expected behavior' do
        expect(instance.method_name).to eq(expected_result)
      end
    end
  end
end
```

#### Test Categories
- **Unit Tests**: Models, services, individual classes
- **Integration Tests**: API endpoints, job processing
- **System Tests**: End-to-end workflows (if applicable)

## Debugging

### Rails Console
```bash
# Start console
bin/rails console

# Access models
user = User.first
trades = Trade.where(status: 'open')

# Test services
service = SomeService.new
result = service.call

# Debug jobs
job = SomeJob.new
job.perform(args)
```

### Debugging Tools

#### Pry Integration
```ruby
# Add to code for debugging
binding.pry

# In Gemfile (development group)
gem 'pry-rails'
gem 'pry-byebug'
```

#### Log Analysis
```bash
# Watch logs in real-time
tail -f log/development.log

# Filter specific patterns
tail -f log/development.log | grep "ERROR"

# Job-specific logs
tail -f log/development.log | grep "FetchCandlesJob"
```

#### Database Debugging
```bash
# PostgreSQL console
psql -d coinbase_futures_bot_development

# Check active connections
SELECT count(*) FROM pg_stat_activity;

# Check table sizes
SELECT schemaname,tablename,pg_size_pretty(size) as size
FROM (
  SELECT schemaname,tablename,pg_relation_size(schemaname||'.'||tablename) as size
  FROM pg_tables WHERE schemaname NOT IN ('information_schema','pg_catalog')
) s ORDER BY size DESC;
```

### Performance Profiling

#### Query Analysis
```ruby
# Enable query logging
ActiveRecord::Base.logger = Logger.new(STDOUT)

# Analyze slow queries
User.joins(:posts).where(posts: { published: true }).explain
```

#### Memory Profiling
```ruby
# Add to Gemfile (development group)
gem 'memory_profiler'

# Profile memory usage
MemoryProfiler.report do
  # Code to profile
end.pretty_print
```

## Working with External APIs

### Coinbase API Testing

#### Sandbox Environment
```bash
# Use sandbox credentials for development
COINBASE_API_KEY=sandbox_key
COINBASE_API_SECRET=sandbox_secret
COINBASE_SANDBOX=true
```

#### API Client Testing
```ruby
# Test API connectivity
client = Coinbase::Client.new
result = client.test_auth
puts result
```

#### Rate Limiting
```ruby
# Monitor rate limits during development
def log_rate_limits(response)
  remaining = response.headers['X-RateLimit-Remaining']
  Rails.logger.info("Rate limit remaining: #{remaining}")
end
```

### Mock Services for Development

#### VCR for HTTP Requests
```ruby
# spec/support/vcr.rb
VCR.configure do |config|
  config.cassette_library_dir = 'spec/fixtures/vcr_cassettes'
  config.hook_into :faraday
  config.configure_rspec_metadata!
end

# Use in tests
it 'fetches market data', vcr: true do
  service.fetch_data
end
```

#### Stubbing External Services
```ruby
# For development/testing
class MockCoinbaseClient
  def fetch_prices
    { 'BTC-USD' => 50000.0, 'ETH-USD' => 3000.0 }
  end
end

# Use mock in development
if Rails.env.development? && ENV['USE_MOCK_API']
  Coinbase::Client = MockCoinbaseClient
end
```

## Local Development Tools

### Database Management

#### pgAdmin Setup
1. Install pgAdmin
2. Connect to local PostgreSQL
3. Navigate to coinbase_futures_bot databases

#### Database Seeds
```ruby
# db/seeds.rb
TradingPair.create!([
  {
    product_id: 'BTC-USD-PERP',
    base_currency: 'BTC',
    quote_currency: 'USD',
    enabled: true
  }
])
```

### Local API Testing

#### cURL Examples
```bash
# Health check
curl http://localhost:3000/up

# Sentiment aggregates
curl "http://localhost:3000/sentiment/aggregates?symbol=BTC-USD-PERP&limit=5"

# Position management
curl -X POST http://localhost:3000/positions \
  -H "Content-Type: application/json" \
  -d '{"product_id": "BTC-USD-PERP"}'
```

#### Postman Collections
Create Postman collections for common API endpoints:
- Health checks
- Position management
- Sentiment data retrieval

## IDE Configuration

### VS Code Settings
```json
{
  "ruby.intellisense": "rubyLocate",
  "ruby.format": "rubocop",
  "ruby.lint": {
    "rubocop": true
  },
  "files.associations": {
    "Gemfile": "ruby",
    "Rakefile": "ruby",
    "*.rake": "ruby"
  }
}
```

### Useful Extensions
- Ruby Language Server
- Ruby Solargraph
- RuboCop
- Rails DB Schema
- GitLens

## Troubleshooting

### Common Development Issues

#### 1. Bundle Install Fails
```bash
# Clear bundle cache
bundle clean --force

# Reinstall gems
rm Gemfile.lock
bundle install
```

#### 2. Database Connection Issues
```bash
# Check PostgreSQL status
brew services list | grep postgresql

# Start PostgreSQL
brew services start postgresql

# Check DATABASE_URL format
echo $DATABASE_URL
```

#### 3. Job Processing Issues
```bash
# Check GoodJob status
bin/rails console
GoodJob.configuration

# Clear job queue
GoodJob::Job.delete_all

# Restart with fresh queue
bin/rails server
```

#### 4. API Authentication Issues
```bash
# Verify credentials format
echo $COINBASE_API_KEY | wc -c

# Test API access
bin/rails console
Coinbase::Client.new.test_auth
```

### Getting Help

#### Documentation Resources
- [Rails Guides](https://guides.rubyonrails.org/)
- [RSpec Documentation](https://rspec.info/)
- [Coinbase API Docs](https://docs.cloud.coinbase.com/)

#### Internal Resources
- [Architecture Documentation](architecture.md)
- [API Documentation](api-endpoints.md)
- [Configuration Guide](configuration.md)

#### Development Team
- Create issues in Linear (FuturesBot project)
- Use GitHub Discussions for questions
- Check existing documentation first

## Performance Best Practices

### Database Optimization
- Use proper indexes for frequent queries
- Avoid N+1 queries with includes/joins
- Use connection pooling appropriately
- Monitor query performance with EXPLAIN

### Job Processing
- Keep jobs idempotent
- Use appropriate retry strategies
- Monitor job queue depth
- Profile long-running jobs

### Memory Management
- Monitor memory usage in development
- Use streaming for large datasets
- Clear ActiveRecord connections properly
- Profile memory leaks with tools

### Code Quality
- Write tests for all new features
- Keep service objects focused and small
- Use proper error handling and logging
- Follow established patterns and conventions
