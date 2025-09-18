# Configuration

## Overview

The coinbase_futures_bot uses **environment variables** for configuration to support different deployment environments and maintain security by keeping sensitive information out of the codebase. This guide covers all configuration options organized by category.

## Environment Setup

### Required Files

#### .ruby-version
```
3.2.4
```

#### .ruby-gemset (if using RVM)
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

# AI Service Configuration (Chat Bot)
OPENROUTER_API_KEY=your_openrouter_api_key
OPENAI_API_KEY=your_openai_api_key

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

**Performance Tuning**:
```bash
# For high-frequency trading
RAILS_MAX_THREADS=10                 # Increase thread pool
DATABASE_POOL_SIZE=15                # Increase connection pool
DATABASE_TIMEOUT=5000                # Connection timeout (ms)
DATABASE_CHECKOUT_TIMEOUT=5          # Pool checkout timeout (seconds)
```

### 2. Coinbase API Configuration

#### API Credentials
```bash
# Advanced Trade API (Futures) - REQUIRED
COINBASE_API_KEY=your_coinbase_api_key
COINBASE_API_SECRET=your_coinbase_private_key_path_or_content

# Alternative credential sources
# Uses cdp_api_key.json file if environment variables not set
```

**Security Best Practices**:
```bash
# Option 1: Direct private key content
COINBASE_API_SECRET="-----BEGIN EC PRIVATE KEY-----
MHcCAQEEIKlL...your_private_key_content...
-----END EC PRIVATE KEY-----"

# Option 2: Path to key file (more secure)
COINBASE_API_SECRET=./cdp_api_key.json

# Option 3: Environment-specific key files
COINBASE_API_SECRET=/secure/path/to/production_key.json
```

#### API Endpoints (Optional Overrides)
```bash
# REST API base URLs
COINBASE_API_BASE_URL=https://api.coinbase.com    # Default
COINBASE_CANDLES_URL=https://api.exchange.coinbase.com/products  # Override candles endpoint
COINBASE_PRODUCTS_URL=https://api.exchange.coinbase.com/products # Override products endpoint

# WebSocket URLs
COINBASE_WS_URL=wss://ws-feed.exchange.coinbase.com              # Spot WebSocket
COINBASE_FUTURES_WS_URL=wss://advanced-trade-ws.coinbase.com     # Futures WebSocket

# Sandbox URLs (for testing)
COINBASE_SANDBOX_API_URL=https://api-public.sandbox.exchange.coinbase.com
COINBASE_SANDBOX_WS_URL=wss://ws-feed-public.sandbox.exchange.coinbase.com
```

#### API Rate Limiting
```bash
# Rate limit configuration
COINBASE_RATE_LIMIT_PER_SECOND=10    # API calls per second
COINBASE_BURST_LIMIT=50              # Burst capacity
COINBASE_RETRY_ATTEMPTS=3            # Retry failed requests
COINBASE_RETRY_DELAY=1               # Delay between retries (seconds)
```

### 3. AI Service Configuration

#### OpenRouter Integration
```bash
# OpenRouter API (primary AI service)
OPENROUTER_API_KEY=your_openrouter_api_key
OPENROUTER_MODEL=anthropic/claude-3.5-sonnet    # Default model
OPENROUTER_MAX_TOKENS=4096                      # Response length limit
OPENROUTER_TEMPERATURE=0.7                      # Creativity level (0-1)
```

#### OpenAI Fallback
```bash
# OpenAI API (fallback service)
OPENAI_API_KEY=your_openai_api_key
OPENAI_MODEL=gpt-4                              # Model selection
OPENAI_MAX_TOKENS=4096                          # Response length limit
OPENAI_TEMPERATURE=0.7                          # Creativity level (0-1)
```

#### Chat Bot Configuration
```bash
# Chat bot behavior
CHAT_BOT_SESSION_TIMEOUT=24                     # Session timeout (hours)
CHAT_BOT_MAX_INTERACTIONS=50                    # Max interactions per session
CHAT_BOT_MEMORY_LIMIT=100                       # Max stored interactions
```

### 4. Sentiment Analysis Configuration

#### CryptoPanic API
```bash
# CryptoPanic news aggregation
CRYPTOPANIC_TOKEN=your_cryptopanic_token
CRYPTOPANIC_AUTH_TOKEN=your_auth_token          # Premium features
CRYPTOPANIC_FILTER=rising                       # News filter (hot, rising, bullish, bearish)
CRYPTOPANIC_REGIONS=en                          # Language regions
CRYPTOPANIC_CURRENCIES=BTC,ETH                  # Tracked currencies
```

#### Sentiment Processing
```bash
# Sentiment analysis configuration
SENTIMENT_ENABLE=true                           # Enable/disable sentiment analysis
SENTIMENT_Z_THRESHOLD=1.2                       # Z-score threshold for signals
SENTIMENT_CONFIDENCE_MIN=0.5                    # Minimum confidence threshold
SENTIMENT_LEXICON_PATH=./config/sentiment_lexicon.json  # Custom lexicon file
```

#### News Sources
```bash
# RSS feed configuration
NEWS_COINDESK_RSS=https://www.coindesk.com/arc/outboundfeeds/rss/
NEWS_COINTELEGRAPH_RSS=https://cointelegraph.com/rss
NEWS_REFRESH_INTERVAL=300                       # Refresh interval (seconds)
NEWS_MAX_AGE_HOURS=24                          # Maximum article age
```

### 5. Trading Configuration

#### Core Trading Settings
```bash
# Trading mode
PAPER_TRADING_MODE=true                         # Enable paper trading (safe default)
DEFAULT_DAY_TRADING=true                        # Default to day trading mode

# Risk management
SIGNAL_EQUITY_USD=50000                         # Default equity for position sizing
MAX_POSITION_SIZE=10                            # Maximum contracts per position
MIN_POSITION_SIZE=1                             # Minimum contracts per position
MAX_DAILY_TRADES=20                             # Maximum trades per day
MAX_CONCURRENT_POSITIONS=5                      # Maximum open positions
```

#### Day Trading Configuration
```bash
# Day trading specific settings
DAY_TRADING_MAX_HOLD_HOURS=8                    # Maximum position hold time
DAY_TRADING_FORCE_CLOSE_TIME="15:30"            # Force close time (EST)
DAY_TRADING_TP_TARGET=0.004                     # Take profit target (40 bps)
DAY_TRADING_SL_TARGET=0.003                     # Stop loss target (30 bps)
DAY_TRADING_MIN_CONFIDENCE=75                   # Minimum signal confidence
```

#### Swing Trading Configuration
```bash
# Swing trading settings
SWING_MAX_HOLD_DAYS=5                           # Maximum hold period
SWING_EXPIRY_BUFFER_DAYS=2                      # Contract expiry buffer
SWING_MAX_EXPOSURE=0.3                          # Maximum overnight exposure (30%)
SWING_ENABLE_ROLL=true                          # Enable contract rollover
SWING_MARGIN_BUFFER=0.2                         # Margin safety buffer (20%)
SWING_MAX_LEVERAGE=3                            # Maximum leverage overnight
```

#### Risk Management
```bash
# Position sizing and risk
POSITION_SIZE_METHOD=kelly                      # kelly, fixed, volatility
KELLY_FRACTION=0.25                             # Conservative Kelly fraction
MAX_RISK_PER_TRADE=0.015                        # 1.5% risk per trade
MAX_PORTFOLIO_RISK=0.06                         # 6% total portfolio risk
VOLATILITY_LOOKBACK_DAYS=20                     # Volatility calculation period

# Stop loss and take profit
DYNAMIC_STOPS=true                              # Enable dynamic stop losses
TRAILING_STOPS=true                             # Enable trailing stops
PROFIT_TARGET_RATIO=1.5                         # Risk/reward ratio
BREAKEVEN_STOP=true                             # Move stop to breakeven at 50% target
```

### 6. Job Scheduling Configuration

#### Cron Schedules
```bash
# Data collection jobs
CANDLES_CRON="0 */1 * * *"                      # Fetch candles (every hour at minute 0)
CANDLES_BACKFILL_DAYS=7                         # Days to backfill on startup

# Sentiment analysis jobs
SENTIMENT_FETCH_CRON="*/5 * * * *"              # Fetch news (every 5 minutes)
SENTIMENT_SCORE_CRON="*/5 * * * *"              # Score sentiment (every 5 minutes)
SENTIMENT_AGG_CRON="*/5 * * * *"                # Aggregate sentiment (every 5 minutes)

# Trading jobs
GENERATE_SIGNALS_CRON="*/15 * * * *"            # Generate signals (every 15 minutes)
RAPID_SIGNALS_CRON="*/1 * * * *"                # Rapid signal evaluation (every minute)
PAPER_CRON="*/15 * * * *"                       # Paper trading (every 15 minutes)

# Position management jobs
DAY_TRADING_MANAGEMENT_CRON="*/5 * * * *"       # Day trading management (every 5 minutes)
SWING_MANAGEMENT_CRON="*/15 * * * *"            # Swing management (every 15 minutes)
END_OF_DAY_CLOSURE_CRON="0 16 * * 1-5"         # End of day closure (4 PM EST, weekdays)

# Risk and monitoring jobs
CONTRACT_EXPIRY_CRON="0 6 * * *"                # Contract expiry check (6 AM UTC)
BASIS_MONITORING_CRON="*/10 * * * *"            # Basis monitoring (every 10 minutes)
HEALTH_CHECK_CRON="*/5 * * * *"                 # Health checks (every 5 minutes)
CALIBRATION_CRON="0 2 * * *"                    # Strategy calibration (2 AM UTC daily)
```

#### Job Processing
```bash
# GoodJob worker configuration
GOOD_JOB_EXECUTION_MODE=async                   # async|external|inline
GOOD_JOB_MAX_THREADS=5                          # Worker thread count
GOOD_JOB_POLL_INTERVAL=10                       # Seconds between job polls
GOOD_JOB_CLEANUP_INTERVAL=1                     # Days to keep job records
GOOD_JOB_ENABLE_CRON=true                       # Enable cron jobs
GOOD_JOB_CRON_TIME_ZONE=UTC                     # Cron timezone
```

### 7. Slack Integration

#### Bot Configuration
```bash
# Slack bot token and webhook
SLACK_BOT_TOKEN=xoxb-your-bot-token
SLACK_WEBHOOK_URL=https://hooks.slack.com/services/your/webhook/url
SLACK_CHANNEL=#trading-alerts                   # Default channel
SLACK_USERNAME=CoinbaseBot                      # Bot display name
SLACK_EMOJI=:robot_face:                        # Bot emoji

# User authorization
SLACK_AUTHORIZED_USERS=U1234567,U7890123        # Comma-separated user IDs
SLACK_ADMIN_USERS=U1234567                      # Admin user IDs
```

#### Notification Settings
```bash
# Notification preferences
SLACK_NOTIFY_SIGNALS=true                       # Signal notifications
SLACK_NOTIFY_TRADES=true                        # Trade execution notifications
SLACK_NOTIFY_ERRORS=true                        # Error notifications
SLACK_NOTIFY_HEALTH=false                       # Health check notifications (can be noisy)

# Notification thresholds
SLACK_MIN_SIGNAL_CONFIDENCE=80                  # Only notify for high-confidence signals
SLACK_MIN_TRADE_SIZE=1000                       # Minimum trade size for notifications
SLACK_ERROR_COOLDOWN=300                        # Error notification cooldown (seconds)
```

#### Command Configuration
```bash
# Slash command settings
SLACK_COMMAND_PREFIX=/bot                       # Command prefix
SLACK_COMMAND_TIMEOUT=30                        # Command timeout (seconds)
SLACK_ENABLE_INTERACTIVE=true                   # Enable interactive components
```

### 8. Monitoring and Observability

#### Sentry Configuration
```bash
# Error tracking and performance monitoring
SENTRY_DSN=your_sentry_dsn
SENTRY_ENVIRONMENT=development                   # Environment tag
SENTRY_RELEASE=v1.0.0                          # Release version
SENTRY_TRACES_SAMPLE_RATE=0.1                  # Performance monitoring sample rate
SENTRY_PROFILES_SAMPLE_RATE=0.1                # Profiling sample rate

# Custom Sentry settings
SENTRY_BEFORE_SEND_TRANSACTION=true             # Filter transactions
SENTRY_MAX_BREADCRUMBS=50                       # Breadcrumb limit
SENTRY_ATTACH_STACKTRACE=true                   # Include stack traces
```

#### Logging Configuration
```bash
# Rails logging
RAILS_LOG_LEVEL=info                            # debug|info|warn|error|fatal
RAILS_LOG_TO_STDOUT=true                        # Log to stdout (for containers)
LOG_TAGS=request_id,user_id                     # Additional log tags

# Custom logging
TRADING_LOG_LEVEL=debug                         # Trading-specific log level
SIGNAL_LOG_VERBOSE=true                         # Verbose signal logging
API_LOG_REQUESTS=false                          # Log all API requests (can be noisy)
```

#### Health Check Configuration
```bash
# Health check settings
HEALTH_CHECK_TIMEOUT=30                         # Health check timeout (seconds)
HEALTH_CHECK_DATABASE=true                      # Include database checks
HEALTH_CHECK_EXTERNAL_APIS=true                 # Include external API checks
HEALTH_CHECK_DISK_USAGE=true                    # Include disk usage checks
HEALTH_CHECK_MEMORY_THRESHOLD=0.8               # Memory usage alert threshold
```

### 9. Rails Environment Configuration

#### Core Settings
```bash
# Rails environment
RAILS_ENV=development                           # development|test|production
SECRET_KEY_BASE=your_secret_key_base            # Required for production
RAILS_SERVE_STATIC_FILES=true                   # Serve static files (production)
FORCE_SSL=false                                 # Force HTTPS (set true for production)
```

#### Server Configuration
```bash
# Puma web server
PORT=3000                                       # Server port
BINDING=0.0.0.0                                # Bind address
RAILS_MAX_THREADS=5                             # Max threads per worker
WEB_CONCURRENCY=1                               # Number of worker processes
PIDFILE=tmp/pids/server.pid                     # PID file location

# Performance tuning
PUMA_WORKERS=2                                  # Number of Puma workers (production)
PUMA_MIN_THREADS=5                              # Minimum threads per worker
PUMA_MAX_THREADS=10                             # Maximum threads per worker
PUMA_PRELOAD_APP=true                           # Preload application (production)
```

### 10. Security Configuration

#### API Security
```bash
# API authentication
SIGNALS_API_KEY=your_secure_api_key             # API key for signal endpoints
API_RATE_LIMIT=100                              # Requests per minute
API_BURST_LIMIT=20                              # Burst capacity

# CORS settings
CORS_ALLOWED_ORIGINS=http://localhost:3000      # Allowed origins
CORS_ALLOWED_METHODS=GET,POST,PUT,DELETE        # Allowed HTTP methods
CORS_ALLOWED_HEADERS=Content-Type,Authorization # Allowed headers
```

#### Encryption and Secrets
```bash
# Encryption keys
ENCRYPTION_KEY=your_32_byte_encryption_key      # For encrypting sensitive data
JWT_SECRET=your_jwt_secret                      # For JWT token signing

# Session security
SESSION_TIMEOUT=24                              # Session timeout (hours)
SECURE_COOKIES=true                             # Secure cookie flag (production)
SAME_SITE_COOKIES=strict                        # SameSite cookie attribute
```

## Configuration by Environment

### Development Environment

```bash
# .env.development
DATABASE_URL=postgresql://localhost:5432/coinbase_futures_bot_development
RAILS_ENV=development
RAILS_LOG_LEVEL=debug

# Safe defaults for development
PAPER_TRADING_MODE=true
SENTIMENT_ENABLE=true
SLACK_NOTIFY_ERRORS=false

# Faster job schedules for testing
CANDLES_CRON="*/5 * * * *"
SENTIMENT_FETCH_CRON="*/2 * * * *"
GENERATE_SIGNALS_CRON="*/5 * * * *"

# Development-friendly settings
GOOD_JOB_EXECUTION_MODE=async
GOOD_JOB_MAX_THREADS=3
API_LOG_REQUESTS=true
```

### Test Environment

```bash
# .env.test
DATABASE_URL=postgresql://localhost:5432/coinbase_futures_bot_test
RAILS_ENV=test

# Disable external services in tests
PAPER_TRADING_MODE=true
SENTIMENT_ENABLE=false
SLACK_NOTIFY_SIGNALS=false
SLACK_NOTIFY_TRADES=false
SLACK_NOTIFY_ERRORS=false

# Fast job execution for tests
GOOD_JOB_EXECUTION_MODE=inline
COINBASE_RATE_LIMIT_PER_SECOND=1000            # No rate limiting in tests
```

### Production Environment

```bash
# Production configuration (use secure secret management)
DATABASE_URL=postgresql://user:pass@prod-host:5432/coinbase_futures_bot_production
RAILS_ENV=production
SECRET_KEY_BASE=secure_secret_key_base
FORCE_SSL=true
RAILS_LOG_LEVEL=info

# Production API credentials (from secure vault)
COINBASE_API_KEY=production_api_key
COINBASE_API_SECRET=/secure/path/to/production_key.json
CRYPTOPANIC_TOKEN=production_token

# Production-ready job processing
GOOD_JOB_EXECUTION_MODE=external
GOOD_JOB_MAX_THREADS=10
WEB_CONCURRENCY=2

# Conservative trading settings
PAPER_TRADING_MODE=false                        # Live trading
SIGNAL_EQUITY_USD=100000                        # Production equity
MAX_POSITION_SIZE=20                            # Higher limits
SENTIMENT_Z_THRESHOLD=1.5                       # More conservative

# Production monitoring
SENTRY_DSN=production_sentry_dsn
SLACK_NOTIFY_SIGNALS=true
SLACK_NOTIFY_TRADES=true
SLACK_NOTIFY_ERRORS=true
HEALTH_CHECK_EXTERNAL_APIS=true

# Production job schedules (more conservative)
CANDLES_CRON="0 */1 * * *"                      # Hourly candle updates
SENTIMENT_FETCH_CRON="*/5 * * * *"              # 5-minute sentiment updates
GENERATE_SIGNALS_CRON="*/15 * * * *"            # 15-minute signal generation
```

## Configuration Validation

### Startup Checks
```ruby
# config/initializers/configuration.rb
Rails.application.configure do
  # Validate required environment variables
  required_vars = %w[
    DATABASE_URL
    COINBASE_API_KEY
    COINBASE_API_SECRET
  ]
  
  missing_vars = required_vars.select { |var| ENV[var].blank? }
  
  if missing_vars.any?
    raise "Missing required environment variables: #{missing_vars.join(', ')}"
  end
  
  # Validate API credentials
  begin
    client = Coinbase::AdvancedTradeClient.new
    client.get_accounts
  rescue => e
    Rails.logger.warn("Coinbase API validation failed: #{e.message}")
  end
  
  # Validate database connection
  ActiveRecord::Base.connection.execute("SELECT 1")
rescue => e
  Rails.logger.error("Configuration validation failed: #{e.message}")
  raise if Rails.env.production?
end
```

### Runtime Configuration Checks
```ruby
class ConfigurationHealthCheck
  def self.validate_all
    {
      database: validate_database,
      coinbase_api: validate_coinbase_api,
      sentiment_api: validate_sentiment_api,
      slack_integration: validate_slack,
      job_processing: validate_job_processing
    }
  end
  
  private
  
  def self.validate_database
    ActiveRecord::Base.connection.execute("SELECT 1")
    { status: :healthy, message: "Database connection successful" }
  rescue => e
    { status: :unhealthy, message: "Database connection failed: #{e.message}" }
  end
  
  def self.validate_coinbase_api
    return { status: :skipped, message: "Paper trading mode" } if ENV["PAPER_TRADING_MODE"] == "true"
    
    client = Coinbase::AdvancedTradeClient.new
    client.get_accounts
    { status: :healthy, message: "Coinbase API connection successful" }
  rescue => e
    { status: :unhealthy, message: "Coinbase API connection failed: #{e.message}" }
  end
end
```

## Best Practices

### 1. Security
- **Never commit secrets**: Use `.env` files and `.gitignore`
- **Use secure storage**: Store production secrets in secure vaults
- **Rotate credentials**: Regularly rotate API keys and secrets
- **Environment separation**: Use different credentials per environment

### 2. Performance
- **Optimize database connections**: Tune pool sizes for workload
- **Configure job processing**: Balance threads and workers
- **Monitor resource usage**: Set appropriate limits and thresholds

### 3. Reliability
- **Validate configuration**: Check required variables at startup
- **Use health checks**: Monitor external dependencies
- **Implement fallbacks**: Configure backup services where possible

### 4. Maintainability
- **Document all variables**: Include comments in configuration files
- **Use consistent naming**: Follow clear naming conventions
- **Group related settings**: Organize configuration by functional area

---

**Next**: [Development](Development) | **Previous**: [Getting Started](Getting-Started) | **Up**: [Home](Home)