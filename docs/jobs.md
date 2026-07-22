# Background Jobs Documentation

## Overview

The coinbase_futures_bot uses GoodJob as the background job processing system, built on PostgreSQL. Jobs handle asynchronous operations including data collection, signal generation, and trading execution.

## Job Processing Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    Job Scheduling Layer                         │
├─────────────────────────────────────────────────────────────────┤
│  Cron Jobs (GoodJob)                                           │
│  • FetchCandlesJob: 5 * * * * (hourly at minute 5)            │
│  • CalibrationJob: 0 2 * * * (daily at 2:00 UTC)             │
│  • SymbolCircuitBreakerJob: 30 2 * * * (daily at 2:30 UTC)   │
│  • HealthCheckJob: 0 * * * * (hourly, 24/7)                  │
│  • FetchCryptopanicJob: */2 * * * * (every 2 minutes)         │
│  • ScoreSentimentJob: */2 * * * * (every 2 minutes)           │
│  • AggregateSentimentJob: */5 * * * * (every 5 minutes)       │
└─────────────────────────────────────────────────────────────────┘
                                    │
┌─────────────────────────────────────────────────────────────────┐
│                     Job Queue Layer                             │
├─────────────────────────────────────────────────────────────────┤
│  Job Categories                                                 │
│  • default: General jobs                                       │
│  • market_data: Data collection jobs                           │
│  • trading: Trading execution jobs                             │
│  • sentiment: Sentiment analysis jobs                          │
└─────────────────────────────────────────────────────────────────┘
                                    │
┌─────────────────────────────────────────────────────────────────┐
│                    Job Execution Layer                          │
├─────────────────────────────────────────────────────────────────┤
│  Worker Processes                                               │
│  • In-process workers (development)                            │
│  • Dedicated workers (production)                              │
│  • Queue-specific workers                                      │
└─────────────────────────────────────────────────────────────────┘
```

## Core Jobs

### Data Collection Jobs

#### FetchCandlesJob

**Purpose**: Fetches OHLCV candle data from Coinbase for technical analysis.

**Schedule**: `5 * * * *` (hourly at minute 5, configurable via `CANDLES_CRON`)

**Parameters**:
- `backfill_days` (integer, default: 7) - Days of historical data to fetch
- `symbols` (array, optional) - Restrict to specific product IDs (nil = all enabled contracts)
- `max_1m_days` (integer, optional) - Raise the 1m depth cap (default `MAX_1M_BACKFILL_DAYS`, 3 days)

**Timeframes**: 1m, 5m, 15m, 30m, 1h, 1d

**Implementation**:
```ruby
class FetchCandlesJob < ApplicationJob
  queue_as :default

  def perform(backfill_days: 7, symbols: nil, max_1m_days: nil)
    rest = MarketData::CoinbaseRest.new
    rest.upsert_products

    # Auto-disable contracts whose expiration_date has passed
    Contract.enabled.where(expiration_date: ...Date.current).find_each { |c| c.update!(enabled: false) }

    scope = Contract.enabled
    scope = scope.where(product_id: symbols) if symbols.present?

    scope.find_each do |pair|
      # 1m/5m/15m/30m/1h/1d, chunked per timeframe;
      # refetches the whole window when stored history is shallower (backward fill)
    end
  end
end
```

**Error Handling**:
- Graceful failure per timeframe
- Continues processing other timeframes if one fails
- Detailed logging for troubleshooting

#### MarketDataSubscribeJob

**Purpose**: Establishes WebSocket connections for real-time market data.

**Execution**: On-demand via Rake tasks

**Parameters**:
- `product_ids` (array) - Trading pairs to subscribe to

**Logic**:
```ruby
def perform(product_ids)
  product_ids = Array(product_ids)
  # No need to check for PERP suffix since we don't support perpetual contracts
  MarketData::CoinbaseFuturesSubscriber.new(product_ids: product_ids).start
  MarketData::CoinbaseSpotSubscriber.new(product_ids: product_ids).start
end
```

> **Note**: the in-code comment about perpetual contracts predates [ADR 0002](adr/0002-perpetual-futures-as-primary-venue.md) — perpetuals (BIP first) are now the adopted primary venue, pending venue migration (#390, which includes generalizing the realtime subscription catalog beyond BIT/ET/NOL).

### Sentiment Analysis Jobs

#### FetchCryptopanicJob

**Purpose**: Collects cryptocurrency news from CryptoPanic API.

**Schedule**: `*/2 * * * *` (every 2 minutes, configurable via `SENTIMENT_FETCH_CRON`)

**Parameters**:
- `currencies` (array, default: ["BTC", "ETH"]) - Cryptocurrencies to fetch news for

**Implementation**:
```ruby
def perform(currencies: ["BTC", "ETH"])
  client = Sentiment::CryptoPanicClient.new

  currencies.each do |currency|
    events = client.fetch_recent_news(currency: currency)
    events.each do |event|
      SentimentEvent.upsert(event, unique_by: [:source, :raw_text_hash])
    end
  end
end
```

**Data Processing**:
- Deduplication via `raw_text_hash`
- Symbol mapping (BTC → BTC-USD)
- Metadata extraction from news articles

#### ScoreSentimentJob

**Purpose**: Applies sentiment scoring to unscored news events.

**Schedule**: `*/2 * * * *` (every 2 minutes, configurable via `SENTIMENT_SCORE_CRON`)

**Scoring Engine**: `Sentiment::SimpleLexiconScorer`

**Implementation**:
```ruby
def perform
  scorer = Sentiment::SimpleLexiconScorer.new

  SentimentEvent.unscored.find_in_batches(batch_size: 100) do |batch|
    batch.each do |event|
      result = scorer.score(event.title)
      event.update!(
        score: result[:score],
        confidence: result[:confidence]
      )
    end
  end
end
```

**Scoring Logic**:
- Lexicon-based sentiment analysis
- Score range: -1.0 (negative) to 1.0 (positive)
- Confidence levels based on keyword matches

#### AggregateSentimentJob

**Purpose**: Creates rolling sentiment aggregates for time windows.

**Schedule**: `*/5 * * * *` (every 5 minutes, configurable via `SENTIMENT_AGG_CRON`)

**Windows**: 5m, 15m, 1h

**Z-Score Calculation**:
```ruby
def calculate_z_score(current_avg, symbol, window)
  past_scores = SentimentAggregate
    .where(symbol: symbol, window: window)
    .where("window_end_at < ?", current_window_end)
    .order(window_end_at: :desc)
    .limit(50)
    .pluck(:avg_score)

  return 0.0 if past_scores.empty?

  mean = past_scores.sum / past_scores.size
  variance = past_scores.sum { |score| (score - mean) ** 2 } / past_scores.size
  std_dev = Math.sqrt(variance)

  std_dev > 0 ? (current_avg - mean) / std_dev : 0.0
end
```

### Trading Jobs

#### GenerateSignalsJob

**Purpose**: Generates trading signals using configured strategies.

**Execution**: On-demand or scheduled

**Parameters**:
- `equity_usd` (float, default: 10,000) - Available equity for position sizing

**Strategy**: `Strategy::MultiTimeframeSignal`

**Implementation**:
```ruby
def perform(equity_usd: default_equity_usd)
  # Profile-aware build — same strategy config the realtime evaluator uses
  strat = Trading::StrategyFactory.multi_timeframe

  Contract.enabled.find_each do |pair|
    order = strat.signal(symbol: pair.product_id, equity_usd: equity_usd)
    # Slack notification + optional execution
  end
end
```

**Signal Processing**:
- Multi-timeframe analysis (1h, 15m, 5m, 1m)
- Risk management and position sizing
- Sentiment filtering integration

#### CalibrationJob

**Purpose**: Tunes the LIVE strategy nightly via walk-forward (out-of-sample) grid search, then persists and **activates** a versioned per-symbol `TradingProfile` that live execution reads via `TradingProfile.effective(symbol:)`. This is a material operational behavior: the tp/sl the bot trades with can change every night.

**Schedule**: `0 2 * * *` (daily at 2:00 UTC, configurable via `CALIBRATE_CRON`)

**Method**:
- Grid: TP targets 100-250 bps x SL targets 50-125 bps, TP > SL candidates only
- Each candidate runs the live-configured `Strategy::MultiTimeframeSignal` (built via `Trading::StrategyFactory`) through `Backtest::WalkForward` — rolling train/eval windows (defaults: 60-day lookback, 14-day train, 7-day eval, 5m step)
- Objective: `drawdown_penalized` by default (total PnL scaled by worst-window drawdown); `total_pnl` also available
- The winner is persisted as a new `TradingProfile` (copying untuned risk knobs — risk_fraction, position sizes, confidence, dedupe — from the symbol's current effective profile) and activated
- Symbols with insufficient candle history, or whose best candidate produced no trades, are skipped

**Per-symbol profile contract**: the realtime evaluator (`RealTimeSignalEvaluator`) reads `min_confidence_threshold`, `deduplication_window`, and `max_signals_per_hour` from the **global** profile only — per-symbol values for those fields are ignored by design. Per-symbol profiles override strategy parameters (tp/sl, risk fraction, position size bounds).

**Implementation sketch**:
```ruby
def perform(symbols: nil, objective: :drawdown_penalized, ...)
  (symbols.presence || Contract.enabled.pluck(:product_id)).each do |symbol|
    candidates = tp_targets.product(sl_targets).select { |tp, sl| tp > sl }
    best = candidates.map { |tp, sl| evaluate_via_walk_forward(symbol, tp, sl) }.max_by { |c| c[:score] }
    persist_and_activate_profile(symbol, best)
  end
end
```

#### SymbolCircuitBreakerJob

**Purpose**: Daily per-symbol circuit breaker — suspends (via `Trading::SymbolSuspension`) any symbol whose trailing 7-day realized gross PnL fails to cover its estimated taker round-trip costs (minimum 5 trades). Suspension blocks new entries only; exits continue, and resume is manual.

**Schedule**: `30 2 * * *` (daily at 2:30 UTC, after calibration; configurable via `CIRCUIT_BREAKER_CRON`)

#### DayTradingPositionManagementJob

**Purpose**: Manages day trading positions with automatic closure and risk management.

**Schedule**: `*/15 * * * *` (every 15 minutes, configurable)

**Queue**: `critical` (high priority for risk management)

**Key Functions**:
- Closes expired day trading positions (opened yesterday)
- Closes positions approaching closure time (within 30 minutes of 24 hours)
- Monitors take profit/stop loss triggers
- Provides position summary and monitoring

**Implementation**:
```ruby
class DayTradingPositionManagementJob < ApplicationJob
  queue_as :critical

  def perform
    @manager = Trading::DayTradingPositionManager.new(logger: @logger)

    # Close expired positions
    if @manager.positions_need_closure?
      closed_count = @manager.close_expired_positions
    end

    # Close approaching positions
    if @manager.positions_approaching_closure?
      closed_count = @manager.close_approaching_positions
    end

    # Check TP/SL triggers
    triggered_positions = @manager.check_tp_sl_triggers
    if triggered_positions.any?
      closed_count = @manager.close_tp_sl_positions
    end

    # Get position summary
    summary = @manager.get_position_summary
  end
end
```

**Error Handling**:
- Graceful failure handling per position
- Continues processing other positions if one fails
- Detailed logging for troubleshooting
- Critical queue ensures high priority execution

#### EndOfDayPositionClosureJob

**Purpose**: Force closes all remaining day trading positions at the end of the trading day.

**Schedule**: `0 0 * * *` (daily at midnight UTC, configurable)

**Queue**: `critical` (highest priority for risk management)

**Key Functions**:
- Force closes all open day trading positions
- Provides final position summary
- Critical for regulatory compliance (day trading rules)

**Implementation**:
```ruby
class EndOfDayPositionClosureJob < ApplicationJob
  queue_as :critical

  def perform
    @manager = Trading::DayTradingPositionManager.new(logger: @logger)

    # Get current position summary
    summary = @manager.get_position_summary

    if summary[:open_count] > 0
      # Force close all remaining day trading positions
      closed_count = @manager.force_close_all_day_trading_positions
    end
  end
end
```

**Error Handling**:
- Critical error handling - job will raise on failure
- Designed for production alerting if positions can't be closed
- Ensures regulatory compliance for day trading

### Utility Jobs

#### TestJob

**Purpose**: Simple job for testing the queue system.

**Implementation**:
```ruby
class TestJob < ApplicationJob
  queue_as :default

  def perform
    Rails.logger.info("TestJob executed at #{Time.current}")
  end
end
```

## Job Configuration

### GoodJob Configuration

**Location**: `config/initializers/good_job.rb`

```ruby
Rails.application.configure do
  # Use GoodJob for Active Job
  config.active_job.queue_adapter = :good_job

  # Cron jobs configuration
  config.good_job.cron = {
    candles_1h: {
      cron: ENV.fetch('CANDLES_CRON', '5 * * * *'),
      class: 'FetchCandlesJob'
    },
    calibrate_daily: {
      cron: ENV.fetch('CALIBRATE_CRON', '0 2 * * *'),
      class: 'CalibrationJob'
    },
    symbol_circuit_breaker: {
      cron: ENV.fetch('CIRCUIT_BREAKER_CRON', '30 2 * * *'),
      class: 'SymbolCircuitBreakerJob'
    },
    fetch_sentiment: {
      cron: ENV.fetch('SENTIMENT_FETCH_CRON', '*/2 * * * *'),
      class: 'FetchCryptopanicJob'
    },
    score_sentiment: {
      cron: ENV.fetch('SENTIMENT_SCORE_CRON', '*/2 * * * *'),
      class: 'ScoreSentimentJob'
    },
    aggregate_sentiment: {
      cron: ENV.fetch('SENTIMENT_AGG_CRON', '*/5 * * * *'),
      class: 'AggregateSentimentJob'
    }
  }

  # Worker configuration
  config.good_job.execution_mode = :async
  config.good_job.max_threads = 5
  config.good_job.poll_interval = 10.seconds
end
```

### Environment Variables

```bash
# Cron schedules (override defaults)
CANDLES_CRON="5 * * * *"           # Hourly candle fetch
CALIBRATE_CRON="0 2 * * *"         # Daily calibration
CIRCUIT_BREAKER_CRON="30 2 * * *"  # Daily symbol circuit breaker
HEALTH_CHECK_CRON="0 * * * *"      # Hourly health check (24/7)
SENTIMENT_FETCH_CRON="*/2 * * * *"  # News fetching
SENTIMENT_SCORE_CRON="*/2 * * * *"  # Sentiment scoring
SENTIMENT_AGG_CRON="*/5 * * * *"    # Sentiment aggregation

# Job-specific parameters
SIGNAL_EQUITY_USD=10000            # Default equity for signals ($10k default)
MAX_1M_BACKFILL_DAYS=3             # Cap on 1m candle backfill depth

# Feature flags
SENTIMENT_ENABLE=true             # Enable sentiment filtering
SENTIMENT_Z_THRESHOLD=1.2         # Z-score threshold for signals
```

## Job Management

### Manual Execution

```ruby
# Execute jobs immediately
FetchCandlesJob.perform_now(backfill_days: 1)
GenerateSignalsJob.perform_now(equity_usd: 5000)
CalibrationJob.perform_now(symbols: ["BTC-USD"])

# Schedule jobs for later
FetchCandlesJob.perform_later(backfill_days: 30)
MarketDataSubscribeJob.perform_later(["BTC-USD"])
```

### Rake Tasks

```bash
# Candle data collection
bin/rake market_data:backfill_candles[7]                    # enqueue background backfill
bin/rails "market_data:backfill[30,'BTC-USD ETH-USD']"      # inline deep backfill (all TFs; products optional)

# Market data subscription
bin/rake market_data:subscribe[BTC-USD]
PRODUCT_IDS=BTC-USD,ETH-USD bin/rake market_data:subscribe

# Backtesting
bin/rails "backtest:run[BTC-USD,2026-05-01,2026-07-01,5m]"
bin/rails "backtest:walk_forward[BTC-USD,2026-05-01,2026-07-01]"

# Signal generation
bin/rake signals:generate
```

## Monitoring and Management

### GoodJob Dashboard

**URL**: `http://localhost:3000/jobs` (basic auth in non-local environments)

**Features**:
- Job queue monitoring
- Execution history
- Performance metrics
- Manual job management
- Error investigation

### Job Status Monitoring

```ruby
# Check job status
job = FetchCandlesJob.perform_later
job.status # => :queued, :running, :succeeded, :discarded

# Job metrics
GoodJob::Job.where(job_class: 'FetchCandlesJob').count
GoodJob::Job.where(finished_at: 1.hour.ago..).average(:duration)
```

### Health Checks

```ruby
# Job system health
def job_system_health
  {
    queue_size: GoodJob::Job.where(finished_at: nil).count,
    failed_jobs: GoodJob::Job.where.not(error: nil).where(finished_at: 1.day.ago..).count,
    last_successful_candles: FetchCandlesJob.last_successful_run,
    worker_status: GoodJob::Process.active.count
  }
end
```

## Error Handling and Retry Logic

### Automatic Retries

```ruby
class FetchCandlesJob < ApplicationJob
  retry_on StandardError, wait: :exponentially_longer, attempts: 3
  discard_on ActiveRecord::RecordInvalid

  def perform(...)
    # Job implementation
  rescue RateLimitError => e
    retry_job(wait: e.retry_after.seconds)
  end
end
```

### Error Notification

The application now includes comprehensive Sentry error tracking for all background jobs:

```ruby
class ApplicationJob < ActiveJob::Base
  rescue_from StandardError do |error|
    # Enhanced Sentry tracking with job context
    Sentry.with_scope do |scope|
      scope.set_tag("job_class", self.class.name)
      scope.set_tag("job_id", job_id)
      scope.set_tag("queue_name", queue_name)
      
      scope.set_context("job_arguments", arguments)
      scope.set_context("job_execution", {
        executions: executions,
        enqueued_at: enqueued_at,
        scheduled_at: scheduled_at
      })
      
      Sentry.capture_exception(error)
    end

    Rails.logger.error("Job failed: #{error.class} - #{error.message}")
    raise error # Allow normal retry/discard logic
  end
end
```

**Features:**
- Automatic error capture with job context
- Job argument and execution metadata
- Queue name and priority tracking
- Breadcrumb trail for debugging
- Integration with retry/discard logic

**Monitoring:**
- All job errors are tracked in Sentry
- Performance monitoring for long-running jobs
- Queue health monitoring
- Failed job rate tracking

See `docs/sentry-monitoring.md` for complete Sentry implementation details.

## Performance Optimization

### Batch Processing

```ruby
def perform_batch_processing
  SentimentEvent.unscored.find_in_batches(batch_size: 100) do |batch|
    scores = batch.map { |event| calculate_score(event) }

    # Bulk update
    updates = batch.zip(scores).map do |event, score|
      { id: event.id, score: score[:score], confidence: score[:confidence] }
    end

    SentimentEvent.upsert_all(updates)
  end
end
```

### Database Connection Management

```ruby
class LongRunningJob < ApplicationJob
  def perform
    ActiveRecord::Base.connection_pool.with_connection do
      # Job logic that requires database access
    end
  ensure
    ActiveRecord::Base.clear_active_connections!
  end
end
```

### Memory Management

```ruby
def process_large_dataset
  dataset.find_in_batches(batch_size: 1000) do |batch|
    process_batch(batch)
    GC.start # Trigger garbage collection between batches
  end
end
```

## Testing

### Job Testing

```ruby
RSpec.describe FetchCandlesJob do
  include ActiveJob::TestHelper

  describe '#perform' do
    it 'fetches candle data successfully' do
      VCR.use_cassette('fetch_candles') do
        expect { described_class.perform_now(backfill_days: 1) }
          .to change { Candle.count }
      end
    end

    it 'handles API errors gracefully' do
      allow_any_instance_of(MarketData::CoinbaseRest)
        .to receive(:upsert_1h_candles)
        .and_raise(APIError)

      expect { described_class.perform_now }.not_to raise_error
    end
  end
end
```

### Integration Testing

```ruby
RSpec.describe 'Job Integration' do
  it 'processes complete sentiment pipeline' do
    FetchCryptopanicJob.perform_now
    ScoreSentimentJob.perform_now
    AggregateSentimentJob.perform_now

    expect(SentimentEvent.count).to be > 0
    expect(SentimentAggregate.count).to be > 0
  end
end
```

## Troubleshooting

### Common Issues

1. **Jobs Not Processing**: Check worker status and queue configuration
2. **Memory Leaks**: Monitor memory usage in long-running jobs
3. **API Rate Limits**: Implement proper retry logic and backoff
4. **Database Deadlocks**: Use proper transaction isolation levels

### Debug Commands

```bash
# Check job queue status
bin/rails console
GoodJob::Job.where(finished_at: nil).count

# View failed jobs
GoodJob::Job.where.not(error: nil).order(:created_at).last(10)

# Monitor job performance
GoodJob::Job.where(job_class: 'FetchCandlesJob').average(:duration)

# Clear failed jobs
GoodJob::Job.where.not(error: nil).delete_all
```

### Production Monitoring

```bash
# Check worker processes
ps aux | grep good_job

# Monitor job execution
tail -f log/production.log | grep "Performed"

# Database job metrics
psql -c "SELECT queue_name, COUNT(*) FROM good_jobs WHERE finished_at IS NULL GROUP BY queue_name;"
```
