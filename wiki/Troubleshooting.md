# Troubleshooting

## Overview

This guide covers common issues, error patterns, and debugging strategies for the coinbase_futures_bot. Use this as your first reference when encountering problems during development, testing, or production deployment.

## Common Issues

### 1. Database Connection Issues

#### Problem: Connection Refused
```
PG::ConnectionBad: could not connect to server: Connection refused
```

**Solutions:**
```bash
# Check PostgreSQL is running
brew services list | grep postgresql  # macOS
sudo systemctl status postgresql      # Linux

# Start PostgreSQL if stopped
brew services start postgresql@14     # macOS
sudo systemctl start postgresql       # Linux

# Test connection manually
psql $DATABASE_URL -c "SELECT 1"

# Check if database exists
psql -l | grep coinbase_futures_bot
```

#### Problem: Authentication Failed
```
PG::ConnectionBad: FATAL: password authentication failed for user
```

**Solutions:**
```bash
# Reset PostgreSQL user password
sudo -u postgres psql
ALTER USER coinbase_bot PASSWORD 'new_password';

# Update DATABASE_URL in .env
DATABASE_URL=postgresql://coinbase_bot:new_password@localhost:5432/coinbase_futures_bot_development

# Verify connection
bin/rails db:migrate:status
```

#### Problem: Database Does Not Exist
```
PG::ConnectionBad: FATAL: database "coinbase_futures_bot_development" does not exist
```

**Solutions:**
```bash
# Create database
bin/rails db:create

# Or create manually
createdb coinbase_futures_bot_development -O coinbase_bot

# Run migrations
bin/rails db:migrate
```

### 2. Coinbase API Issues

#### Problem: Authentication Errors
```
Coinbase::Client::AuthenticationError: Invalid API key
```

**Solutions:**
```bash
# Verify API key format
echo $COINBASE_API_KEY
# Should be: organizations/{org_id}/apiKeys/{key_id}

# Check private key file exists and is readable
ls -la cdp_api_key.json
cat cdp_api_key.json  # Should show PEM format key

# Test API connection in Rails console
bin/rails console
client = Coinbase::AdvancedTradeClient.new
client.get_accounts  # Should not raise error
```

#### Problem: Rate Limiting
```
Coinbase::Client::RateLimitError: Rate limit exceeded
```

**Solutions:**
```bash
# Reduce API call frequency in .env
COINBASE_RATE_LIMIT_PER_SECOND=5
CANDLES_CRON="0 */2 * * *"  # Every 2 hours instead of hourly

# Implement exponential backoff
# Check config/initializers/coinbase.rb for retry logic

# Monitor API usage
tail -f log/development.log | grep "Coinbase API"
```

#### Problem: Invalid Product ID
```
Coinbase::Client::NotFoundError: Product not found
```

**Solutions:**
```bash
# Sync products from Coinbase
bin/rails console
MarketData::CoinbaseRest.new.upsert_products

# Check available products
TradingPair.pluck(:product_id)

# Verify product is enabled
TradingPair.enabled.where(product_id: "BTC-USD").exists?
```

### 3. Background Job Issues

#### Problem: Jobs Not Processing
```
# Jobs stuck in queue, not executing
```

**Solutions:**
```bash
# Check GoodJob worker is running
ps aux | grep good_job

# Start GoodJob worker if not running
bundle exec good_job start

# Check job queue status
bin/rails console
GoodJob::Job.where(finished_at: nil).count

# Clear stuck jobs (development only)
GoodJob::Job.where(finished_at: nil).where("created_at < ?", 1.hour.ago).destroy_all
```

#### Problem: Job Failures
```
# Jobs failing with errors
```

**Solutions:**
```bash
# Check GoodJob dashboard
open http://localhost:3000/good_job

# View recent job errors
bin/rails console
GoodJob::Execution.where.not(error: nil).order(created_at: :desc).limit(5).pluck(:error)

# Retry failed jobs
GoodJob::Job.where.not(error: nil).find_each(&:retry)

# Check specific job logs
tail -f log/development.log | grep "FetchCandlesJob"
```

#### Problem: Cron Jobs Not Scheduling
```
# Scheduled jobs not running at expected times
```

**Solutions:**
```bash
# Verify cron configuration
bin/rails console
puts ENV['CANDLES_CRON']  # Should show cron expression

# Check cron jobs are enabled
GoodJob.configuration.enable_cron  # Should be true

# List scheduled cron jobs
GoodJob::CronEntry.all.each { |entry| puts "#{entry.key}: #{entry.cron}" }

# Force run cron job manually
FetchCandlesJob.perform_later
```

### 4. Market Data Issues

#### Problem: No Candle Data
```
# Empty candle data preventing signal generation
```

**Solutions:**
```bash
# Check if trading pairs exist
bin/rails console
TradingPair.enabled.count  # Should be > 0

# Fetch candles manually
FetchCandlesJob.perform_now(backfill_days: 7)

# Verify candles were created
Candle.for_symbol("BTC-USD").count

# Check candle data quality
Candle.for_symbol("BTC-USD").hourly.order(:timestamp).last(5).pluck(:timestamp, :close)
```

#### Problem: WebSocket Connection Issues
```
# Real-time data not updating
```

**Solutions:**
```bash
# Check WebSocket connectivity
bin/rails console
subscriber = MarketData::CoinbaseSpotSubscriber.new(
  product_ids: ["BTC-USD"],
  on_ticker: ->(tick) { puts "Price: #{tick['price']}" }
)
# Should connect and show price updates

# Check network connectivity
curl -I https://ws-feed.exchange.coinbase.com
ping ws-feed.exchange.coinbase.com

# Restart WebSocket connections
# Kill and restart background job worker
```

#### Problem: Stale Market Data
```
# Market data not updating regularly
```

**Solutions:**
```bash
# Check last candle timestamp
bin/rails console
Candle.for_symbol("BTC-USD").hourly.maximum(:timestamp)

# Force candle update
MarketData::CoinbaseRest.new.upsert_1h_candles("BTC-USD", 4.hours.ago, Time.current)

# Check fetch job schedule
GoodJob::CronEntry.find_by(key: "FetchCandlesJob")&.cron
```

### 5. Signal Generation Issues

#### Problem: No Signals Generated
```
# Strategy not producing any signals
```

**Solutions:**
```bash
# Check signal generation manually
bin/rails console
strategy = Strategy::MultiTimeframeSignal.new
signal = strategy.signal(symbol: "BTC-USD", equity_usd: 50000)
puts signal || "No signal generated"

# Check candle data sufficiency
candles_1h = Candle.for_symbol("BTC-USD").hourly.count
puts "1h candles: #{candles_1h} (need >= 60)"

# Check sentiment data
SentimentAggregate.where(symbol: "BTC", window: "15m").order(:window_end_at).last&.z_score

# Lower confidence threshold temporarily
ENV['SIGNAL_CONFIDENCE_THRESHOLD'] = '60'
```

#### Problem: All Signals Filtered Out
```
# Signals generated but filtered by sentiment or other criteria
```

**Solutions:**
```bash
# Check sentiment threshold
echo $SENTIMENT_Z_THRESHOLD  # Default: 1.2

# Lower sentiment threshold
export SENTIMENT_Z_THRESHOLD=0.8

# Check sentiment data availability
bin/rails console
SentimentAggregate.where(symbol: "BTC", window: "15m").count

# Disable sentiment filtering temporarily
export SENTIMENT_ENABLE=false
```

#### Problem: Low Confidence Signals
```
# Signals have low confidence scores
```

**Solutions:**
```bash
# Check confidence calculation factors
bin/rails console
strategy = Strategy::MultiTimeframeSignal.new
# Add debug logging to confidence calculation

# Review market conditions
# - Low volatility periods produce lower confidence
# - Sideways markets reduce trend strength
# - Check EMA alignment and separation

# Adjust confidence thresholds for testing
ENV['SIGNAL_CONFIDENCE_THRESHOLD'] = '50'
```

### 6. Testing Issues

#### Problem: Test Database Issues
```
# Tests failing due to database problems
```

**Solutions:**
```bash
# Reset test database
RAILS_ENV=test bin/rails db:reset

# Check test database connection
RAILS_ENV=test bin/rails db:migrate:status

# Clear test database
RAILS_ENV=test bin/rails db:test:prepare
```

#### Problem: VCR Cassette Issues
```
# VCR cassettes failing or outdated
```

**Solutions:**
```bash
# Delete and regenerate cassettes
rm -rf spec/fixtures/vcr_cassettes/

# Run tests to regenerate cassettes
bundle exec rspec spec/services/coinbase/

# Update specific cassette
VCR_MODE=all bundle exec rspec spec/services/coinbase/advanced_trade_client_spec.rb
```

#### Problem: Flaky Tests
```
# Tests passing/failing inconsistently
```

**Solutions:**
```bash
# Run test multiple times to identify flakiness
for i in {1..10}; do bundle exec rspec spec/flaky_spec.rb; done

# Add proper test isolation
# Check for shared state between tests
# Use proper before/after hooks

# Fix time-dependent tests
# Use Timecop.freeze or travel_to for consistent time
```

### 7. Configuration Issues

#### Problem: Environment Variables Not Loading
```
# Configuration not being read correctly
```

**Solutions:**
```bash
# Check .env file exists and is readable
ls -la .env
cat .env | grep COINBASE_API_KEY

# Verify dotenv is loading
bin/rails console
puts ENV['COINBASE_API_KEY']  # Should show your key

# Check for syntax errors in .env
# No spaces around = sign
# Quotes for values with spaces
```

#### Problem: Invalid Configuration Values
```
# Configuration values causing errors
```

**Solutions:**
```bash
# Validate configuration in Rails console
bin/rails console

# Check database URL format
puts ENV['DATABASE_URL']
# Should be: postgresql://user:pass@host:port/database

# Check API key format
puts ENV['COINBASE_API_KEY']
# Should be: organizations/{org_id}/apiKeys/{key_id}

# Test configuration parsing
Rails.application.config.default_day_trading  # Should be boolean
```

## Debugging Strategies

### 1. Log Analysis

#### Rails Logs
```bash
# Watch logs in real-time
tail -f log/development.log

# Filter specific components
tail -f log/development.log | grep "SignalAlert"
tail -f log/development.log | grep "ERROR"

# Search for specific patterns
grep -n "Coinbase API" log/development.log | tail -20
```

#### GoodJob Logs
```bash
# GoodJob specific logs
tail -f log/development.log | grep "GoodJob"

# Job execution logs
grep "Job.*performed" log/development.log

# Failed job logs
grep "Job.*failed" log/development.log
```

### 2. Rails Console Debugging

#### Database Queries
```ruby
# Check recent data
Candle.for_symbol("BTC-USD").hourly.order(:timestamp).last(5)
SignalAlert.active.order(:alert_timestamp).last(5)
Position.open.includes(:trading_pair)

# Check data consistency
TradingPair.enabled.count
Candle.distinct.pluck(:symbol)
SentimentAggregate.distinct.pluck(:symbol, :window)
```

#### Service Testing
```ruby
# Test services directly
rest_client = MarketData::CoinbaseRest.new
rest_client.upsert_products

strategy = Strategy::MultiTimeframeSignal.new
signal = strategy.signal(symbol: "BTC-USD", equity_usd: 50000)

sentiment = Sentiment::CryptoPanicClient.new
news = sentiment.fetch_news(currencies: ["BTC"], limit: 10)
```

#### Job Testing
```ruby
# Run jobs manually
FetchCandlesJob.perform_now
GenerateSignalsJob.perform_now(equity_usd: 25000)
ScoreSentimentJob.perform_now

# Check job queue
GoodJob::Job.where(finished_at: nil).count
GoodJob::Job.where.not(error: nil).pluck(:job_class, :error).first(3)
```

### 3. Network Debugging

#### API Connectivity
```bash
# Test Coinbase API connectivity
curl -I https://api.coinbase.com/v2/exchange-rates

# Test WebSocket connectivity
curl -I https://ws-feed.exchange.coinbase.com

# Check DNS resolution
nslookup api.coinbase.com
```

#### SSL/TLS Issues
```bash
# Test SSL certificate
openssl s_client -connect api.coinbase.com:443 -servername api.coinbase.com

# Check certificate chain
curl -vI https://api.coinbase.com/v2/exchange-rates 2>&1 | grep -i certificate
```

### 4. Performance Debugging

#### Database Performance
```sql
-- Check slow queries (in PostgreSQL)
SELECT query, mean_time, calls, total_time 
FROM pg_stat_statements 
ORDER BY total_time DESC 
LIMIT 10;

-- Check connection pool usage
SELECT count(*), state 
FROM pg_stat_activity 
WHERE datname = 'coinbase_futures_bot_development' 
GROUP BY state;
```

#### Memory Usage
```bash
# Check Rails memory usage
ps aux | grep rails

# Check database connections
bin/rails console
ActiveRecord::Base.connection_pool.stat
```

## Error Patterns and Solutions

### 1. Common Error Messages

#### "No route matches"
```ruby
# Error: ActionController::RoutingError: No route matches [GET] "/signals"

# Solution: Check routes file
bin/rails routes | grep signals

# Verify controller exists
ls app/controllers/*signal*
```

#### "Uninitialized constant"
```ruby
# Error: NameError: uninitialized constant Strategy::MultiTimeframeSignal

# Solution: Check file naming and class definition
ls app/services/strategy/
# File should be: multi_timeframe_signal.rb
# Class should be: Strategy::MultiTimeframeSignal
```

#### "Connection pool timeout"
```ruby
# Error: ActiveRecord::ConnectionTimeoutError

# Solution: Increase pool size or check for connection leaks
# In database.yml:
pool: 10  # Increase from default 5

# Check for unclosed connections in code
```

### 2. API-Specific Errors

#### Coinbase API Errors
```ruby
# 401 Unauthorized
# - Check API key format and permissions
# - Verify private key file is readable
# - Check system clock is synchronized

# 403 Forbidden  
# - API key may not have required permissions
# - Check account status and verification

# 429 Rate Limited
# - Reduce API call frequency
# - Implement exponential backoff
# - Check for multiple instances making calls

# 500 Internal Server Error
# - Coinbase API issue, check status page
# - Implement retry logic with backoff
```

#### WebSocket Errors
```ruby
# Connection refused
# - Check network connectivity
# - Verify WebSocket URL is correct
# - Check for firewall blocking connections

# Authentication failed
# - WebSocket may require different auth than REST
# - Check WebSocket-specific credentials

# Connection drops frequently
# - Implement reconnection logic
# - Check network stability
# - Add heartbeat/ping mechanism
```

### 3. Job Processing Errors

#### Job Retry Exhaustion
```ruby
# When jobs fail repeatedly and exhaust retries

# Check error patterns
failed_jobs = GoodJob::Job.where.not(error: nil)
error_patterns = failed_jobs.group(:error).count

# Common solutions:
# - Fix underlying issue (API credentials, network)
# - Increase retry attempts for transient errors
# - Add custom retry logic for specific error types
```

#### Memory Leaks in Jobs
```ruby
# Jobs consuming increasing memory

# Solutions:
# - Process data in smaller batches
# - Clear large objects explicitly
# - Use find_each instead of all for large datasets
# - Monitor memory usage in job logs
```

## Health Monitoring

### 1. System Health Checks

#### Built-in Health Endpoints
```bash
# Basic health check
curl http://localhost:3000/up

# Extended health check
curl http://localhost:3000/health

# Signal system health
curl http://localhost:3000/signals/health
```

#### Custom Health Checks
```ruby
# Add custom health checks in HealthController
def extended_health
  {
    database: check_database_health,
    jobs: check_job_health,
    apis: check_api_health,
    memory: check_memory_usage
  }
end
```

### 2. Monitoring Scripts

#### Database Health Script
```bash
#!/bin/bash
# Check database health
psql $DATABASE_URL -c "
SELECT 
  'connections' as metric,
  count(*) as value 
FROM pg_stat_activity 
WHERE datname = 'coinbase_futures_bot_development';

SELECT 
  'candles_today' as metric,
  count(*) as value 
FROM candles 
WHERE created_at >= CURRENT_DATE;
"
```

#### Job Queue Monitoring
```bash
#!/bin/bash
# Monitor job queue health
bin/rails runner "
puts 'Queued jobs: ' + GoodJob::Job.where(finished_at: nil).count.to_s
puts 'Failed jobs: ' + GoodJob::Job.where.not(error: nil).count.to_s
puts 'Jobs last hour: ' + GoodJob::Job.where('created_at > ?', 1.hour.ago).count.to_s
"
```

## Prevention Strategies

### 1. Proactive Monitoring

#### Set up monitoring for:
- Database connection pool usage
- API rate limit consumption
- Job queue depth and failure rates
- Memory and CPU usage
- Disk space utilization

### 2. Error Tracking

#### Configure Sentry for:
- Automatic error capture and alerting
- Performance monitoring
- Release tracking
- Custom error context

### 3. Logging Strategy

#### Implement structured logging:
- Use consistent log formats
- Include request IDs for tracing
- Log important business events
- Set appropriate log levels per environment

### 4. Testing Strategy

#### Comprehensive testing:
- Unit tests for all business logic
- Integration tests for API endpoints
- Job testing with proper mocking
- Performance tests for critical paths

---

**Next**: [Contributing](Contributing) | **Previous**: [Testing Guide](Testing-Guide) | **Up**: [Home](Home)