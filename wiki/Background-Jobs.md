# Background Jobs

## Overview

The coinbase_futures_bot uses **GoodJob** as its background job processing system with **25+ background jobs** that handle data ingestion, signal generation, position management, and system monitoring. All jobs are designed for reliability, observability, and efficient resource utilization.

## Job Processing Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        GoodJob Framework                        │
├─────────────────────────────────────────────────────────────────┤
│  • PostgreSQL-based job queue                                  │
│  • Cron scheduling with sub-minute precision                   │
│  • Job retry and error handling                                │
│  • Dashboard UI at /good_job (development)                     │
│  • Concurrent job processing                                   │
└─────────────────────────────────────────────────────────────────┘
                                    │
┌─────────────────────────────────────────────────────────────────┐
│                        Job Categories                           │
├─────────────────────────────────────────────────────────────────┤
│  Data Ingestion (4 jobs)        │  Position Management (6 jobs) │
│  • Market data collection       │  • Day trading management     │
│  • News and sentiment data      │  • Swing position tracking    │
│  • Real-time subscriptions      │  • Position closure logic     │
│                                 │  • Risk monitoring           │
├─────────────────────────────────┼─────────────────────────────────┤
│  Signal Processing (4 jobs)     │  Risk & Monitoring (8 jobs)   │
│  • Multi-timeframe analysis     │  • Contract expiry tracking   │
│  • Real-time signal evaluation  │  • Basis monitoring           │
│  • Rapid signal generation      │  • Health checks              │
│  • Signal monitoring           │  • System calibration         │
└─────────────────────────────────────────────────────────────────┘
```

## Job Categories

### 1. Data Ingestion Jobs (4 jobs)

#### FetchCandlesJob
**File**: `app/jobs/fetch_candles_job.rb`  
**Queue**: `:default`  
**Schedule**: Configurable via `CANDLES_CRON` (default: `"0 5 * * *"` - hourly at minute 5)

**Purpose**: Fetches historical OHLCV candle data from Coinbase REST API for multiple timeframes.

**Key Features**:
- **Multi-timeframe Support**: 1m, 5m, 15m, 1h candles
- **Backfill Logic**: Configurable backfill period (default: 7 days)
- **Chunked Fetching**: Handles large date ranges efficiently
- **Product Synchronization**: Updates trading pair metadata

**Configuration**:
```bash
CANDLES_CRON="0 5 * * *"        # Schedule (hourly at minute 5)
CANDLES_BACKFILL_DAYS=7         # Days to backfill on startup
```

**Usage**:
```ruby
# Manual execution
FetchCandlesJob.perform_later(backfill_days: 3)

# Processes enabled products: BTC-USD, ETH-USD
```

#### FetchCryptopanicJob
**File**: `app/jobs/fetch_cryptopanic_job.rb`  
**Queue**: `:default`  
**Schedule**: `"*/2 * * * *"` (every 2 minutes)

**Purpose**: Collects cryptocurrency news from CryptoPanic API for sentiment analysis.

**Key Features**:
- **Multi-currency Support**: BTC, ETH, and other major cryptocurrencies
- **Deduplication**: Prevents duplicate news entries
- **Rate Limit Handling**: Respects API rate limits
- **Error Recovery**: Robust error handling and retry logic

**Configuration**:
```bash
CRYPTOPANIC_TOKEN=your_api_token
SENTIMENT_FETCH_CRON="*/2 * * * *"
```

#### FetchNewsJob
**File**: `app/jobs/fetch_news_job.rb`  
**Queue**: `:default`  
**Schedule**: `"*/5 * * * *"` (every 5 minutes)

**Purpose**: Aggregates news from multiple RSS sources for comprehensive sentiment analysis.

**Key Features**:
- **Multi-source Aggregation**: CoinDesk, CoinTelegraph, and other sources
- **RSS Feed Processing**: Handles various RSS formats
- **Content Normalization**: Standardizes article format
- **Source Prioritization**: Weights different news sources

#### MarketDataSubscribeJob
**File**: `app/jobs/market_data_subscribe_job.rb`  
**Queue**: `:realtime`  
**Schedule**: On-demand (triggered by system events)

**Purpose**: Manages WebSocket connections for real-time market data streaming.

**Key Features**:
- **Connection Management**: Maintains persistent WebSocket connections
- **Automatic Reconnection**: Handles connection drops and network issues
- **Multi-product Subscription**: Subscribes to multiple trading pairs
- **Real-time Processing**: Processes ticks and updates candles

### 2. Signal Processing Jobs (4 jobs)

#### GenerateSignalsJob
**File**: `app/jobs/generate_signals_job.rb`  
**Queue**: `:default`  
**Schedule**: Configurable (typically every 15 minutes)

**Purpose**: Main signal generation using multi-timeframe analysis strategy.

**Key Features**:
- **Multi-timeframe Analysis**: 1h trend, 15m confirmation, 5m entry
- **Sentiment Integration**: Applies sentiment filtering
- **Risk Management**: Position sizing and risk controls
- **Slack Notifications**: Sends signal alerts to Slack

**Configuration**:
```bash
SIGNAL_EQUITY_USD=50000         # Equity for position sizing
GENERATE_SIGNALS_CRON="*/15 * * * *"
```

**Usage**:
```ruby
GenerateSignalsJob.perform_later(equity_usd: 50000)
```

#### RapidSignalEvaluationJob
**File**: `app/jobs/rapid_signal_evaluation_job.rb`  
**Queue**: `:default`  
**Schedule**: High-frequency (triggered by price movements)

**Purpose**: High-frequency signal evaluation for day trading precision.

**Key Features**:
- **1-minute Precision**: Uses 1m and 5m timeframes for rapid entry
- **Day Trading Optimization**: Tighter stops (30-40 bps) and quick profits
- **Real-time Triggers**: Responds to significant price movements
- **Contract Resolution**: Automatic current-month contract selection

**Parameters**:
```ruby
perform(
  product_id: "BTC-USD",
  current_price: 45000.0,
  asset: "BTC",
  day_trading: true
)
```

#### RealTimeSignalJob
**File**: `app/jobs/real_time_signal_job.rb`  
**Queue**: `:realtime_signals`  
**Schedule**: Continuous (every 30 seconds)

**Purpose**: Continuous real-time signal evaluation and alert management.

**Key Features**:
- **Continuous Monitoring**: Evaluates all enabled trading pairs
- **Alert Management**: Creates and manages SignalAlert records
- **Signal Cleanup**: Removes expired signals
- **Statistics Tracking**: Monitors signal performance

**Configuration**:
```ruby
# Configurable evaluation interval
start_realtime_evaluation(interval_seconds: 30)
```

#### RealTimeMonitoringJob
**File**: `app/jobs/real_time_monitoring_job.rb`  
**Queue**: `:monitoring`  
**Schedule**: Every minute

**Purpose**: Monitors real-time system performance and market conditions.

**Key Features**:
- **System Health**: Monitors job queue and database performance
- **Market Monitoring**: Tracks price movements and volatility
- **Alert Generation**: Sends alerts for unusual conditions
- **Performance Metrics**: Collects system performance data

### 3. Sentiment Analysis Jobs (3 jobs)

#### ScoreSentimentJob
**File**: `app/jobs/score_sentiment_job.rb`  
**Queue**: `:default`  
**Schedule**: `"*/2 * * * *"` (every 2 minutes)

**Purpose**: Applies lexicon-based sentiment scoring to collected news articles.

**Key Features**:
- **Lexicon-based Scoring**: Uses sentiment word analysis
- **Confidence Calculation**: Provides confidence scores
- **Batch Processing**: Processes multiple articles efficiently
- **Score Normalization**: Standardizes sentiment scores

#### AggregateSentimentJob
**File**: `app/jobs/aggregate_sentiment_job.rb`  
**Queue**: `:default`  
**Schedule**: `"*/5 * * * *"` (every 5 minutes)

**Purpose**: Creates time-windowed sentiment aggregates for strategy use.

**Key Features**:
- **Time Windows**: 15-minute, 1-hour, 4-hour, and 24-hour windows
- **Statistical Analysis**: Mean, weighted scores, and z-scores
- **Rolling Aggregation**: Maintains moving windows
- **Strategy Integration**: Provides sentiment signals for trading

**Time Windows**:
- **15m**: Short-term sentiment for rapid signals
- **1h**: Intraday sentiment context
- **4h**: Medium-term sentiment trends
- **24h**: Daily sentiment baseline

### 4. Position Management Jobs (6 jobs)

#### DayTradingPositionManagementJob
**File**: `app/jobs/day_trading_position_management_job.rb`  
**Queue**: `:critical`  
**Schedule**: Every 5 minutes during market hours

**Purpose**: Manages intraday positions with same-day closure requirements.

**Key Features**:
- **Intraday Monitoring**: Continuous position tracking
- **Time-based Risk**: Automatic position closure before market close
- **P&L Tracking**: Real-time profit/loss calculation
- **Risk Adjustments**: Dynamic stop-loss and take-profit updates

#### SwingPositionManagementJob
**File**: `app/jobs/swing_position_management_job.rb`  
**Queue**: `:default`  
**Schedule**: Every 15 minutes

**Purpose**: Manages multi-day swing trading positions.

**Key Features**:
- **Multi-day Positions**: Handles overnight position management
- **Contract Rollover**: Manages contract expiration
- **Risk Monitoring**: Overnight exposure limits
- **Margin Management**: Leverage and margin monitoring

#### EndOfDayPositionClosureJob
**File**: `app/jobs/end_of_day_position_closure_job.rb`  
**Queue**: `:critical`  
**Schedule**: Daily at market close (typically 4:00 PM ET)

**Purpose**: Forces closure of all day trading positions before market close.

**Key Features**:
- **Forced Closure**: Ensures day trading compliance
- **Market Order Execution**: Uses market orders for guaranteed fills
- **P&L Settlement**: Calculates final day trading P&L
- **Position Cleanup**: Cleans up position records

#### PositionCloseJob
**File**: `app/jobs/position_close_job.rb`  
**Queue**: `:critical`  
**Schedule**: On-demand (triggered by stop-loss or take-profit)

**Purpose**: Executes position closure orders with comprehensive error handling.

**Key Features**:
- **Order Execution**: Places closure orders via Coinbase API
- **Error Recovery**: Handles partial fills and order failures
- **Notification**: Sends closure notifications to Slack
- **Audit Trail**: Maintains detailed closure records

#### SwingPositionCleanupJob
**File**: `app/jobs/swing_position_cleanup_job.rb`  
**Queue**: `:default`  
**Schedule**: Daily at 2:00 AM UTC

**Purpose**: Cleans up expired or invalid swing trading positions.

**Key Features**:
- **Expired Position Cleanup**: Removes positions past maximum hold period
- **Contract Expiry Handling**: Manages expired futures contracts
- **Data Cleanup**: Removes stale position records
- **Reporting**: Generates cleanup reports

#### SwingRiskMonitoringJob
**File**: `app/jobs/swing_risk_monitoring_job.rb`  
**Queue**: `:monitoring`  
**Schedule**: Every 30 minutes

**Purpose**: Monitors risk metrics for swing trading positions.

**Key Features**:
- **Overnight Exposure**: Monitors total overnight exposure
- **Leverage Limits**: Ensures leverage stays within limits
- **Margin Monitoring**: Tracks margin usage and requirements
- **Risk Alerts**: Sends alerts when risk limits are approached

### 5. Risk & Monitoring Jobs (8 jobs)

#### ContractExpiryMonitoringJob
**File**: `app/jobs/contract_expiry_monitoring_job.rb`  
**Queue**: `:critical`  
**Schedule**: Daily at 6:00 AM UTC

**Purpose**: Monitors futures contract expiration and manages rollover process.

**Key Features**:
- **Expiry Tracking**: Monitors contract expiration dates
- **Buffer Period**: Configurable buffer before expiration
- **Position Closure**: Forces position closure before expiry
- **Rollover Management**: Handles contract rollover process
- **Emergency Checks**: On-demand emergency expiry checks

**Configuration**:
```bash
CONTRACT_EXPIRY_BUFFER_DAYS=2   # Days before expiry to close positions
```

#### FuturesBasisMonitoringJob
**File**: `app/jobs/futures_basis_monitoring_job.rb`  
**Queue**: `:default`  
**Schedule**: Every 10 minutes

**Purpose**: Monitors futures-spot basis for arbitrage opportunities and risk management.

**Key Features**:
- **Basis Calculation**: Tracks futures-spot price differential
- **Arbitrage Detection**: Identifies arbitrage opportunities
- **Risk Monitoring**: Monitors basis risk for open positions
- **Historical Tracking**: Maintains basis history for analysis

**Thresholds**:
```bash
BASIS_THRESHOLD_BPS=50          # Basis threshold in basis points
BASIS_ARBITRAGE_THRESHOLD_BPS=50
```

#### MarginWindowMonitoringJob
**File**: `app/jobs/margin_window_monitoring_job.rb`  
**Queue**: `:critical`  
**Schedule**: Every 15 minutes during market hours

**Purpose**: Monitors margin requirements and account health.

**Key Features**:
- **Margin Tracking**: Monitors available margin
- **Risk Alerts**: Sends alerts when margin is low
- **Position Limits**: Enforces margin-based position limits
- **Account Health**: Monitors overall account health

#### ArbitrageOpportunityJob
**File**: `app/jobs/arbitrage_opportunity_job.rb`  
**Queue**: `:default`  
**Schedule**: Triggered by basis monitoring

**Purpose**: Evaluates and potentially executes arbitrage opportunities.

**Key Features**:
- **Opportunity Validation**: Confirms arbitrage is still valid
- **Risk Limits**: Enforces arbitrage position limits
- **Execution Logic**: Coordinates spot and futures trades
- **Performance Tracking**: Monitors arbitrage performance

#### HealthCheckJob
**File**: `app/jobs/health_check_job.rb`  
**Queue**: `:monitoring`  
**Schedule**: Every 5 minutes

**Purpose**: Comprehensive system health monitoring and alerting.

**Key Features**:
- **Database Health**: Monitors database connections and performance
- **Job Queue Health**: Monitors GoodJob queue status
- **API Connectivity**: Tests external API connections
- **Memory Usage**: Monitors application memory usage
- **Error Rate Monitoring**: Tracks error rates and patterns

**Health Checks**:
- Database connectivity and query performance
- GoodJob queue status and job failure rates
- Coinbase API connectivity and response times
- Memory usage and garbage collection
- WebSocket connection status

#### CalibrationJob
**File**: `app/jobs/calibration_job.rb`  
**Queue**: `:default`  
**Schedule**: `"0 2 * * *"` (daily at 2:00 AM UTC)

**Purpose**: Calibrates trading strategy parameters based on market conditions.

**Key Features**:
- **Parameter Optimization**: Adjusts strategy parameters
- **Market Regime Detection**: Identifies changing market conditions
- **Performance Analysis**: Analyzes recent strategy performance
- **Adaptive Configuration**: Updates configuration based on analysis

#### PaperTradingJob
**File**: `app/jobs/paper_trading_job.rb`  
**Queue**: `:default`  
**Schedule**: `"*/15 * * * *"` (every 15 minutes)

**Purpose**: Executes paper trading simulation for strategy validation.

**Key Features**:
- **Realistic Simulation**: Simulates real trading conditions
- **Performance Tracking**: Tracks simulated P&L
- **Strategy Validation**: Validates strategies before live trading
- **Risk-free Testing**: Tests new features without capital risk

#### TestJob
**File**: `app/jobs/test_job.rb`  
**Queue**: `:default`  
**Schedule**: On-demand (development only)

**Purpose**: Testing job for development and debugging.

**Key Features**:
- **Development Testing**: Tests job infrastructure
- **Error Testing**: Tests error handling and retry logic
- **Performance Testing**: Tests job performance under load

## Job Scheduling System

### Cron Configuration

Jobs use GoodJob's cron functionality for reliable scheduling:

```ruby
# In job classes
class MyJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency
  
  good_job_control_concurrency_with(
    perform_limit: 1,
    key: -> { "#{self.class.name}" }
  )
  
  def self.cron
    ENV.fetch("MY_JOB_CRON", "*/5 * * * *")
  end
end
```

### Job Dependencies

Some jobs have dependencies and run in sequence:

```
Data Flow Dependencies:
1. FetchCandlesJob → GenerateSignalsJob
2. FetchCryptopanicJob → ScoreSentimentJob → AggregateSentimentJob
3. GenerateSignalsJob → RapidSignalEvaluationJob
4. Position Jobs → Risk Monitoring Jobs
```

### Queue Priorities

Jobs are organized by priority queues:

- **`:critical`** - Time-sensitive operations (position management, expiry monitoring)
- **`:realtime_signals`** - Real-time signal processing
- **`:monitoring`** - System monitoring and health checks
- **`:default`** - Standard background processing

## Error Handling & Retry Logic

### Retry Configuration

Jobs implement sophisticated retry logic:

```ruby
class MyJob < ApplicationJob
  # Exponential backoff retry
  retry_on StandardError, wait: :exponentially_longer, attempts: 3
  
  # Custom retry for specific errors
  retry_on Faraday::TimeoutError, wait: 30.seconds, attempts: 5
  
  # Discard certain errors
  discard_on ArgumentError
end
```

### Error Tracking

All jobs integrate with Sentry for error tracking:

```ruby
def perform
  # Job logic
rescue => e
  Sentry.with_scope do |scope|
    scope.set_tag("job_class", self.class.name)
    scope.set_context("job_context", job_context)
    Sentry.capture_exception(e)
  end
  raise
end
```

### Dead Job Handling

Failed jobs are handled gracefully:

- **Automatic Retry**: Jobs retry with exponential backoff
- **Dead Letter Queue**: Permanently failed jobs are preserved
- **Manual Intervention**: Failed jobs can be manually retried
- **Alert System**: Critical job failures trigger Slack alerts

## Monitoring & Observability

### Job Dashboard

GoodJob provides a web dashboard at `/good_job` (development only):

- **Job Status**: View running, queued, and failed jobs
- **Performance Metrics**: Job execution times and throughput
- **Queue Management**: Manage job queues and priorities
- **Error Analysis**: Analyze job failures and patterns

### Performance Monitoring

Jobs are monitored for performance:

```ruby
# Job performance tracking
def perform
  start_time = Time.current
  
  # Job logic here
  
  duration = Time.current - start_time
  Rails.logger.info("Job completed in #{duration}s")
  
  # Track in Sentry
  SentryHelper.add_breadcrumb(
    message: "Job completed",
    data: { duration: duration, job_class: self.class.name }
  )
end
```

### Health Monitoring

HealthCheckJob monitors overall job system health:

- **Queue Status**: Monitors job queue depth and processing rate
- **Failure Rates**: Tracks job failure rates and patterns
- **Resource Usage**: Monitors memory and CPU usage
- **External Dependencies**: Tests API connectivity and response times

## Configuration

### Environment Variables

Key configuration variables for job system:

```bash
# Job Processing
GOOD_JOB_EXECUTION_MODE=async      # async|external|inline
GOOD_JOB_MAX_THREADS=5             # Worker thread count
GOOD_JOB_POLL_INTERVAL=10          # Seconds between job polls

# Job Schedules
CANDLES_CRON="0 5 * * *"           # Candle fetching
SENTIMENT_FETCH_CRON="*/2 * * * *"  # Sentiment collection
GENERATE_SIGNALS_CRON="*/15 * * * *" # Signal generation
CALIBRATE_CRON="0 2 * * *"         # Strategy calibration

# Risk Management
CONTRACT_EXPIRY_BUFFER_DAYS=2      # Contract expiry buffer
BASIS_THRESHOLD_BPS=50             # Basis monitoring threshold
MAX_ARBITRAGE_POSITIONS=2          # Arbitrage position limit
```

### Production Configuration

Production job configuration:

```bash
# High-performance settings
GOOD_JOB_EXECUTION_MODE=external
GOOD_JOB_MAX_THREADS=10
WEB_CONCURRENCY=2

# Conservative schedules
CANDLES_CRON="0 */1 * * *"         # Hourly candle updates
SENTIMENT_FETCH_CRON="*/5 * * * *"  # 5-minute sentiment updates
```

## Testing Jobs

Jobs are thoroughly tested with RSpec:

```ruby
# spec/jobs/generate_signals_job_spec.rb
RSpec.describe GenerateSignalsJob do
  describe "#perform" do
    it "generates signals for enabled trading pairs" do
      create(:trading_pair, product_id: "BTC-USD", enabled: true)
      
      expect(SlackNotificationService).to receive(:signal_generated)
      
      described_class.new.perform(equity_usd: 10000)
    end
  end
end
```

### Job Testing Patterns

- **Mock External APIs**: Use VCR for API interactions
- **Test Error Handling**: Verify retry and error handling logic
- **Validate Side Effects**: Ensure jobs produce expected outcomes
- **Performance Testing**: Test job performance under load

---

**Next**: [API Reference](API-Reference) | **Previous**: [Services Guide](Services-Guide) | **Up**: [Home](Home)