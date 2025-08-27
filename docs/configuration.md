# Configuration Documentation

## Overview

The coinbase_futures_bot uses environment variables for configuration to support different deployment environments and maintain security by keeping sensitive information out of the codebase.

## Environment Setup

### Required Files

#### .ruby-version
```
3.2.4
```

#### .ruby-gemset
```
coinbase_futures_bot
```

#### .env (Development)
**Location**: Project root (gitignored)

```bash
# Database Configuration
DATABASE_URL=postgresql://username:password@localhost:5432/coinbase_futures_bot_development

# Coinbase API Configuration
COINBASE_API_KEY=your_api_key_here
COINBASE_API_SECRET=your_api_secret_here

# CryptoPanic API
CRYPTOPANIC_TOKEN=your_cryptopanic_token

# Feature Flags
SENTIMENT_ENABLE=true
SENTIMENT_Z_THRESHOLD=1.2

# Job Schedules (optional overrides)
CANDLES_CRON="0 5 * * *"
PAPER_CRON="*/15 * * * *"
CALIBRATE_CRON="0 2 * * *"
```

## Configuration Categories

### 1. Database Configuration

#### Core Settings
```bash
# Primary database connection
DATABASE_URL=postgresql://user:pass@host:port/database_name

# Connection pool size (default: 5)
RAILS_MAX_THREADS=5

# Development/test database names (fallback if DATABASE_URL not set)
PGDATABASE=coinbase_futures_bot_development  # for development
PGDATABASE=coinbase_futures_bot_test         # for test
```

#### Connection Pool Configuration
```ruby
# config/database.yml
default: &default
  adapter: postgresql
  encoding: unicode
  pool: <%= ENV.fetch("RAILS_MAX_THREADS") { 5 } %>
  url: <%= ENV["DATABASE_URL"] %>
```

### 2. Coinbase API Configuration

#### API Credentials
```bash
# Advanced Trade API (Futures)
COINBASE_API_KEY=your_coinbase_api_key
COINBASE_API_SECRET=your_coinbase_private_key

# Alternative credential sources
# Uses cdp_api_key.json file if environment variables not set
```

#### API Endpoints
```bash
# REST API base URLs (optional overrides)
COINBASE_AT_REST_URL=https://api.coinbase.com           # Advanced Trade
COINBASE_EXCHANGE_REST_URL=https://api.exchange.coinbase.com  # Exchange

# WebSocket URLs
COINBASE_FUTURES_WS_URL=wss://advanced-trade-ws.coinbase.com
COINBASE_SPOT_WS_URL=wss://ws-feed.exchange.coinbase.com

# Market data endpoints (optional overrides)
COINBASE_CANDLES_URL=https://api.exchange.coinbase.com/products/%s/candles
COINBASE_PRODUCTS_URL=https://api.exchange.coinbase.com/products
```

#### Rate Limiting
```bash
# API request limits (internal configuration)
MAX_REQUESTS_PER_SECOND=10
BURST_ALLOWANCE=20
RATE_LIMIT_WINDOW=60
```

### 3. External Service Configuration

#### CryptoPanic API
```bash
# News sentiment data source
CRYPTOPANIC_TOKEN=your_cryptopanic_api_token

# API endpoint (optional override)
CRYPTOPANIC_BASE_URL=https://cryptopanic.com/api/v1
```

#### Sentry Error Tracking
```bash
# Error monitoring (optional)
SENTRY_DSN=your_sentry_dsn_url
SENTRY_ENVIRONMENT=development|staging|production
```

### 4. Feature Flags

#### Sentiment Analysis
```bash
# Enable sentiment filtering in trading strategies
SENTIMENT_ENABLE=true|false  # default: false

# Z-score threshold for sentiment filtering
SENTIMENT_Z_THRESHOLD=1.2    # default: 1.2

# Sentiment processing settings
SENTIMENT_SYMBOLS=BTC-USD,ETH-USD  # default symbols
```

#### Trading Features
```bash
# Paper trading mode
PAPER_TRADING_MODE=true|false  # default: false

# Risk management
BASIS_THRESHOLD_BPS=50         # basis threshold in basis points
MAX_POSITION_SIZE=5            # maximum contracts per position
MIN_POSITION_SIZE=1            # minimum contracts per position

# Strategy parameters
SIGNAL_EQUITY_USD=10000        # default equity for signal generation
```

### 5. Job Scheduling Configuration

#### Cron Schedules
```bash
# Data collection jobs
CANDLES_CRON="0 5 * * *"           # Fetch candles (hourly at minute 5)
CANDLES_BACKFILL_DAYS=7            # Days to backfill

# Sentiment analysis jobs
SENTIMENT_FETCH_CRON="*/2 * * * *"  # Fetch news (every 2 minutes)
SENTIMENT_SCORE_CRON="*/2 * * * *"  # Score sentiment (every 2 minutes)
SENTIMENT_AGG_CRON="*/5 * * * *"    # Aggregate sentiment (every 5 minutes)

# Trading jobs
PAPER_CRON="*/15 * * * *"          # Paper trading (every 15 minutes)
CALIBRATE_CRON="0 2 * * *"         # Strategy calibration (daily at 2 AM UTC)
```

#### Job Processing
```bash
# GoodJob worker configuration
GOOD_JOB_EXECUTION_MODE=async      # async|external|inline
GOOD_JOB_MAX_THREADS=5             # worker thread count
GOOD_JOB_POLL_INTERVAL=10          # seconds between job polls
GOOD_JOB_CLEANUP_INTERVAL=1        # days to keep job records
```

### 6. Rails Environment Configuration

#### Core Settings
```bash
# Rails environment
RAILS_ENV=development|test|production

# Application settings
SECRET_KEY_BASE=your_secret_key_base  # for production
RAILS_LOG_LEVEL=debug|info|warn|error|fatal

# Force SSL in production
FORCE_SSL=true|false
```

#### Server Configuration
```bash
# Puma web server
PORT=3000                          # server port
RAILS_MAX_THREADS=5               # max threads per worker
WEB_CONCURRENCY=1                 # number of worker processes

# Binding and networking
BINDING=0.0.0.0                   # bind address
PIDFILE=tmp/pids/server.pid       # PID file location
```

### 7. Development Configuration

#### Debug Settings
```bash
# Development helpers
INLINE=1                          # run jobs inline (for debugging)
DEBUG=true                        # enable debug logging

# Test database
TEST_DATABASE_URL=postgresql://user:pass@host:port/test_db
```

#### Local Overrides
```bash
# Local development overrides
LOCAL_COINBASE_WS_URL=ws://localhost:8080  # for local testing
MOCK_COINBASE_API=true                     # use mock API responses
DISABLE_RATE_LIMITING=true                 # disable rate limits
```

## Configuration by Environment

### Development Environment

```bash
# .env.development
DATABASE_URL=postgresql://localhost:5432/coinbase_futures_bot_development
RAILS_ENV=development
RAILS_LOG_LEVEL=debug

# Enable all features for testing
SENTIMENT_ENABLE=true
PAPER_TRADING_MODE=true

# Faster job schedules for development
CANDLES_CRON="*/5 * * * *"
SENTIMENT_FETCH_CRON="*/1 * * * *"

# Mock external services
MOCK_COINBASE_API=false  # set to true for offline development
```

### Test Environment

```bash
# .env.test
DATABASE_URL=postgresql://localhost:5432/coinbase_futures_bot_test
RAILS_ENV=test

# Disable external API calls in tests
MOCK_COINBASE_API=true
DISABLE_EXTERNAL_APIS=true

# Fast job execution for tests
GOOD_JOB_EXECUTION_MODE=inline
```

### Production Environment

```bash
# Production configuration (use secure secret management)
DATABASE_URL=postgresql://user:pass@prod-host:5432/coinbase_futures_bot_production
RAILS_ENV=production
SECRET_KEY_BASE=secure_secret_key_base

# API credentials (from secure vault)
COINBASE_API_KEY=production_api_key
COINBASE_API_SECRET=production_private_key
CRYPTOPANIC_TOKEN=production_token

# Production-ready settings
FORCE_SSL=true
RAILS_LOG_LEVEL=info
SENTRY_DSN=production_sentry_dsn

# Conservative feature flags
SENTIMENT_ENABLE=true
SENTIMENT_Z_THRESHOLD=1.5
BASIS_THRESHOLD_BPS=30

# Production job schedules
GOOD_JOB_EXECUTION_MODE=external
GOOD_JOB_MAX_THREADS=10
```

## Configuration Loading Order

### 1. Environment Variables
Direct environment variables take highest precedence:
```bash
export DATABASE_URL=postgresql://localhost/mydb
```

### 2. .env Files
Loaded by dotenv gem in development/test:
```ruby
# config/application.rb
Dotenv::Railtie.load if ['development', 'test'].include?(Rails.env)
```

### 3. Default Values
Fallback values defined in code:
```ruby
# Using ENV.fetch with defaults
timeout = ENV.fetch('API_TIMEOUT', 30).to_i
enabled = ENV.fetch('FEATURE_ENABLED', 'false') == 'true'
```

### 4. Configuration Files
Rails configuration files:
```ruby
# config/environments/production.rb
Rails.application.configure do
  config.force_ssl = ENV.fetch('FORCE_SSL', 'true') == 'true'
end
```

## Security Best Practices

### 1. Credential Management

#### Environment Variables
```bash
# ✅ Good: Use environment variables for secrets
export COINBASE_API_KEY=abc123

# ❌ Bad: Hard-code secrets in files
COINBASE_API_KEY="abc123"  # in tracked files
```

#### File-based Credentials
```bash
# ✅ Good: Use gitignored credential files
echo "api_key" > .env
echo ".env" >> .gitignore

# ❌ Bad: Commit credential files
git add cdp_api_key.json  # contains private keys
```

### 2. Production Deployment

#### Secret Management
```bash
# Use your platform's secret management
# Examples:
kubectl create secret generic app-secrets \
  --from-literal=database-url="postgresql://..." \
  --from-literal=coinbase-api-key="..."

# Heroku
heroku config:set COINBASE_API_KEY=abc123

# Docker
docker run -e COINBASE_API_KEY=abc123 app
```

#### Environment Separation
```bash
# Separate credentials per environment
# Development
export COINBASE_API_KEY=sandbox_key

# Production
export COINBASE_API_KEY=production_key
```

## Configuration Validation

### Startup Checks
```ruby
# config/initializers/configuration.rb
Rails.application.configure do
  # Validate required environment variables
  required_vars = %w[DATABASE_URL]
  required_vars << 'COINBASE_API_KEY' if Rails.env.production?

  missing_vars = required_vars.reject { |var| ENV.key?(var) }

  if missing_vars.any?
    raise "Missing required environment variables: #{missing_vars.join(', ')}"
  end
end
```

### Health Checks
```ruby
# app/controllers/health_controller.rb
def configuration_check
  {
    database: database_accessible?,
    coinbase_api: coinbase_api_accessible?,
    required_env_vars: required_env_vars_present?
  }
end
```

## Configuration Testing

### Environment Variable Testing
```ruby
# spec/support/environment_helper.rb
RSpec.configure do |config|
  config.before(:each) do
    # Reset environment for tests
    stub_env('SENTIMENT_ENABLE', 'false')
    stub_env('PAPER_TRADING_MODE', 'true')
  end
end

def stub_env(key, value)
  allow(ENV).to receive(:[]).with(key).and_return(value)
  allow(ENV).to receive(:fetch).with(key, any_args).and_return(value)
end
```

### Configuration Specs
```ruby
RSpec.describe 'Configuration' do
  describe 'sentiment settings' do
    it 'uses default threshold when not configured' do
      stub_env('SENTIMENT_Z_THRESHOLD', nil)
      expect(SentimentConfig.threshold).to eq(1.2)
    end

    it 'uses configured threshold when set' do
      stub_env('SENTIMENT_Z_THRESHOLD', '2.0')
      expect(SentimentConfig.threshold).to eq(2.0)
    end
  end
end
```

## Troubleshooting

### Common Configuration Issues

#### 1. Database Connection
```bash
# Check DATABASE_URL format
echo $DATABASE_URL
# Should be: postgresql://user:pass@host:port/database

# Test connection
bin/rails db:prepare
```

#### 2. API Credentials
```bash
# Verify credential format
echo $COINBASE_API_KEY | wc -c  # Should be reasonable length

# Test API access
bin/rails console
Coinbase::Client.new.test_auth
```

#### 3. Job Processing
```bash
# Check GoodJob configuration
bin/rails console
GoodJob.configuration
```

### Debug Commands

```bash
# View all environment variables
env | grep -E "(COINBASE|DATABASE|SENTIMENT|GOOD_JOB)"

# Check Rails configuration
bin/rails console
Rails.application.config.database_configuration

# Validate configuration
bin/rails console
Rails.application.config_for(:application)
```

### Configuration Monitoring

```ruby
# Monitor configuration changes
class ConfigurationMonitor
  def self.check_changes
    current_config = ENV.to_h.slice(*MONITORED_VARS)
    if current_config != previous_config
      Rails.logger.warn("Configuration changed: #{changes}")
      notify_admin(changes)
    end
  end
end
```

## Migration and Updates

### Configuration Version Control
```bash
# Track configuration schema
echo "v1.2.0" > .config-version

# Document breaking changes in configuration
# CHANGELOG.md entry for config changes
```

### Backward Compatibility
```ruby
# Support deprecated environment variables
def api_key
  ENV['COINBASE_API_KEY'] || ENV['DEPRECATED_API_KEY']
end

# Warn about deprecated configuration
if ENV['DEPRECATED_VAR']
  Rails.logger.warn("DEPRECATED_VAR is deprecated, use NEW_VAR")
end
```
