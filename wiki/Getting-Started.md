# Getting Started

## Overview

This guide will help you set up and run the Coinbase Futures Bot locally for development or testing. The bot is designed for **day trading** with intraday position management and comprehensive risk controls.

## Prerequisites

### System Requirements

- **Operating System**: macOS, Linux, or WSL2 on Windows
- **Ruby**: 3.2.4 (specified in `.ruby-version`)
- **PostgreSQL**: 12.0 or later
- **Git**: For version control
- **Node.js**: Optional, for any frontend tooling

### Required Accounts & APIs

1. **Coinbase Account**
   - Coinbase Pro/Advanced Trade account
   - API credentials with futures trading permissions
   - Sufficient funds for trading (or use sandbox/paper trading)

2. **CryptoPanic API** (Optional but recommended)
   - Free API token for news sentiment analysis
   - Sign up at [cryptopanic.com](https://cryptopanic.com/developers/api/)

3. **Slack Integration** (Optional)
   - Slack workspace for notifications
   - Bot token for posting messages

## Installation

### 1. Clone the Repository

```bash
git clone git@github.com:Skeyelab/coinbase_futures_bot.git
cd coinbase_futures_bot
```

### 2. Ruby Environment Setup

#### Using RVM (Recommended)
```bash
# Install RVM if not already installed
curl -sSL https://get.rvm.io | bash -s stable

# Install and use Ruby 3.2.4 with project gemset
rvm use ruby-3.2.4@coinbase_futures_bot --create

# Verify Ruby version
ruby -v  # Should show ruby 3.2.4
```

#### Using rbenv
```bash
# Install rbenv if not already installed
brew install rbenv  # macOS
# or follow instructions at https://github.com/rbenv/rbenv

# Install Ruby 3.2.4
rbenv install 3.2.4
rbenv local 3.2.4

# Verify installation
ruby -v  # Should show ruby 3.2.4
```

### 3. Install Dependencies

```bash
# Install bundler if not already installed
gem install bundler

# Install project dependencies
bundle install
```

### 4. Database Setup

#### Install PostgreSQL

**macOS (Homebrew)**:
```bash
brew install postgresql@14
brew services start postgresql@14
```

**Ubuntu/Debian**:
```bash
sudo apt update
sudo apt install postgresql postgresql-contrib
sudo systemctl start postgresql
sudo systemctl enable postgresql
```

#### Create Database User

```bash
# Connect to PostgreSQL as superuser
sudo -u postgres psql

# Create user and databases
CREATE USER coinbase_bot WITH PASSWORD 'your_password' CREATEDB;
CREATE DATABASE coinbase_futures_bot_development OWNER coinbase_bot;
CREATE DATABASE coinbase_futures_bot_test OWNER coinbase_bot;

# Grant permissions
GRANT ALL PRIVILEGES ON DATABASE coinbase_futures_bot_development TO coinbase_bot;
GRANT ALL PRIVILEGES ON DATABASE coinbase_futures_bot_test TO coinbase_bot;

\q
```

### 5. Environment Configuration

#### Create Environment File

Create a `.env` file in the project root:

```bash
cp .env.example .env  # If example exists
# or create new .env file
touch .env
```

#### Configure Environment Variables

Edit `.env` with your configuration:

```bash
# Database Configuration
DATABASE_URL=postgresql://coinbase_bot:your_password@localhost:5432/coinbase_futures_bot_development

# Coinbase API Configuration (REQUIRED)
COINBASE_API_KEY=your_coinbase_api_key
COINBASE_API_SECRET=your_coinbase_private_key_path_or_content

# CryptoPanic API (Optional but recommended)
CRYPTOPANIC_TOKEN=your_cryptopanic_token

# Trading Configuration
PAPER_TRADING_MODE=true              # Start with paper trading
SIGNAL_EQUITY_USD=10000              # Virtual equity for signals
DEFAULT_DAY_TRADING=true             # Enable day trading mode

# Feature Flags
SENTIMENT_ENABLE=true                # Enable sentiment analysis
SENTIMENT_Z_THRESHOLD=1.2            # Sentiment threshold for signals

# Job Schedules (Optional - uses defaults if not set)
CANDLES_CRON="0 */1 * * *"          # Fetch candles hourly
SENTIMENT_FETCH_CRON="*/5 * * * *"   # Fetch news every 5 minutes
GENERATE_SIGNALS_CRON="*/15 * * * *" # Generate signals every 15 minutes

# Slack Integration (Optional)
SLACK_BOT_TOKEN=xoxb-your-bot-token
SLACK_WEBHOOK_URL=https://hooks.slack.com/services/your/webhook/url
SLACK_AUTHORIZED_USERS=U1234567,U7890123  # Comma-separated user IDs

# API Security (Optional)
SIGNALS_API_KEY=your_secure_api_key  # For API access

# Logging and Monitoring
RAILS_LOG_LEVEL=info
SENTRY_DSN=your_sentry_dsn          # Optional error tracking
```

#### Coinbase API Setup

**Option 1: Environment Variables**
```bash
COINBASE_API_KEY=your_api_key
COINBASE_API_SECRET=your_private_key_content
```

**Option 2: Key File (More Secure)**
```bash
# Save your Coinbase private key to a file
echo "-----BEGIN EC PRIVATE KEY-----
your_private_key_content_here
-----END EC PRIVATE KEY-----" > cdp_api_key.json

# Reference the file in environment
COINBASE_API_SECRET=./cdp_api_key.json
```

### 6. Database Initialization

```bash
# Prepare database (create, migrate, seed)
bin/rails db:prepare

# Or run steps individually
bin/rails db:create
bin/rails db:migrate
bin/rails db:seed  # Optional: loads sample data
```

### 7. Verify Installation

#### Run Tests
```bash
# Run the test suite to verify everything works
bundle exec rspec

# Run with coverage
COVERAGE=true bundle exec rspec
```

#### Check System Health
```bash
# Start Rails console
bin/rails console

# Test database connection
ActiveRecord::Base.connection.execute("SELECT 1")
# => Should return result without error

# Test Coinbase API (if configured)
client = Coinbase::AdvancedTradeClient.new
client.get_accounts.first(3)
# => Should return account information

# Exit console
exit
```

## Running the Application

### 1. Start the Web Server

```bash
# Start Rails server
bin/rails server

# Or with specific port
bin/rails server -p 3000
```

The application will be available at:
- **Web Interface**: http://localhost:3000
- **API Health Check**: http://localhost:3000/up
- **Extended Health**: http://localhost:3000/health
- **GoodJob Dashboard**: http://localhost:3000/good_job (development only)

### 2. Start Background Jobs

In a separate terminal:

```bash
# Start GoodJob worker for background processing
bundle exec good_job start

# Or start with specific configuration
GOOD_JOB_MAX_THREADS=3 bundle exec good_job start
```

### 3. Verify System Operation

#### Check Health Endpoints
```bash
# Basic health check
curl http://localhost:3000/up

# Extended health with database info
curl http://localhost:3000/health

# Signal system health
curl http://localhost:3000/signals/health
```

#### Monitor Logs
```bash
# Watch Rails logs
tail -f log/development.log

# Watch GoodJob logs (if running separately)
tail -f log/good_job.log
```

## Initial Configuration

### 1. Sync Trading Pairs

```bash
# Start Rails console
bin/rails console

# Sync products from Coinbase
rest = MarketData::CoinbaseRest.new
rest.upsert_products

# Verify trading pairs were created
TradingPair.enabled.count
# => Should show enabled trading pairs

# Check specific pairs
TradingPair.where(product_id: ["BTC-USD", "ETH-USD"])
```

### 2. Fetch Initial Market Data

```bash
# In Rails console, fetch initial candle data
FetchCandlesJob.perform_now(backfill_days: 7)

# Verify candles were created
Candle.for_symbol("BTC-USD").hourly.count
# => Should show candle data
```

### 3. Test Signal Generation

```bash
# Generate test signals
GenerateSignalsJob.perform_now(equity_usd: 10000)

# Check generated signals
SignalAlert.active.count
# => Should show any generated signals

# View recent signals
SignalAlert.recent(1).limit(5).pluck(:symbol, :side, :confidence)
```

## Development Workflow

### 1. Running Tests

```bash
# Run full test suite
bundle exec rspec

# Run specific test file
bundle exec rspec spec/services/strategy/multi_timeframe_signal_spec.rb

# Run tests with coverage
COVERAGE=true bundle exec rspec

# View coverage report
open coverage/index.html
```

### 2. Code Quality

```bash
# Run StandardRB linter
bin/standardrb

# Auto-fix StandardRB issues
bin/standardrb --fix

# Run security scanner
bundle exec brakeman
```

### 3. Database Operations

```bash
# Create new migration
bin/rails generate migration AddFieldToModel field:type

# Run migrations
bin/rails db:migrate

# Rollback migration
bin/rails db:rollback

# Reset database (development only)
bin/rails db:reset
```

### 4. Background Job Management

```bash
# View job status in console
bin/rails console

# Check job queue
GoodJob::Job.where(finished_at: nil).count

# View recent job executions
GoodJob::Execution.order(created_at: :desc).limit(10)

# Clear failed jobs
GoodJob::Job.where.not(error: nil).destroy_all
```

## Common Tasks

### Market Data Collection

```bash
# Fetch latest candles
bin/rails runner "FetchCandlesJob.perform_now"

# Fetch news and sentiment
bin/rails runner "FetchCryptopanicJob.perform_now"
bin/rails runner "ScoreSentimentJob.perform_now"
bin/rails runner "AggregateSentimentJob.perform_now"
```

### Signal Generation

```bash
# Generate signals manually
bin/rails runner "GenerateSignalsJob.perform_now(equity_usd: 50000)"

# Evaluate rapid signals for BTC
bin/rails runner "
  RapidSignalEvaluationJob.perform_now(
    product_id: 'BTC-USD',
    current_price: 45000.0,
    asset: 'BTC',
    day_trading: true
  )
"
```

### Position Management

```bash
# View open positions
bin/rails console
Position.open.each { |p| puts "#{p.product_id}: #{p.side} #{p.size} @ #{p.entry_price}" }

# Close all day trading positions (end of day)
bin/rails runner "EndOfDayPositionClosureJob.perform_now"
```

## Troubleshooting

### Common Issues

#### Database Connection Errors
```bash
# Check PostgreSQL is running
brew services list | grep postgresql  # macOS
sudo systemctl status postgresql      # Linux

# Test connection manually
psql $DATABASE_URL -c "SELECT 1"

# Check database exists
psql -l | grep coinbase_futures_bot
```

#### Coinbase API Errors
```bash
# Test API credentials in console
bin/rails console
client = Coinbase::AdvancedTradeClient.new
client.get_accounts  # Should not raise error

# Check API key permissions
# - Ensure futures trading is enabled
# - Verify API key has correct permissions
# - Check rate limits aren't exceeded
```

#### Missing Dependencies
```bash
# Reinstall gems
bundle install

# Update gems (carefully)
bundle update

# Check for system dependencies
# On macOS: brew install postgresql
# On Ubuntu: apt install postgresql-dev
```

#### Job Processing Issues
```bash
# Check GoodJob dashboard
open http://localhost:3000/good_job

# Clear stuck jobs
bin/rails console
GoodJob::Job.where(finished_at: nil).where("created_at < ?", 1.hour.ago).destroy_all

# Restart job processing
# Kill existing good_job process and restart
pkill -f good_job
bundle exec good_job start
```

### Getting Help

1. **Check Logs**: Always check `log/development.log` first
2. **Health Endpoints**: Use `/health` and `/signals/health` to check system status
3. **Test Suite**: Run tests to verify system integrity
4. **Documentation**: Refer to other wiki pages for specific topics
5. **GitHub Issues**: Check existing issues or create new ones

## Next Steps

Once you have the system running:

1. **Explore the API**: See [API Reference](API-Reference) for endpoint documentation
2. **Understand Services**: Review [Services Guide](Services-Guide) for business logic
3. **Configure Strategies**: See [Trading Strategies](Trading-Strategies) for strategy details
4. **Set Up Monitoring**: Review [Monitoring](Monitoring) for observability setup
5. **Deploy to Production**: See [Deployment](Deployment) for production setup

---

**Next**: [Configuration](Configuration) | **Previous**: [Database Schema](Database-Schema) | **Up**: [Home](Home)