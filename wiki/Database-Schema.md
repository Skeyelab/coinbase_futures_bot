# Database Schema

## Overview

The coinbase_futures_bot uses **PostgreSQL** as its primary database with a schema optimized for time-series data, trading operations, and real-time signal processing. The database consists of **8 core tables** plus **GoodJob tables** for background job management.

## Database Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Core Trading Tables                      │
├─────────────────────────────────────────────────────────────────┤
│  trading_pairs          │  positions              │  candles     │
│  • Product metadata     │  • Active positions     │  • OHLCV data│
│  • Contract info        │  • P&L tracking         │  • Multi-TF  │
│  • Expiration dates     │  • Day/swing trading    │  • Real-time │
└─────────────────────────────────────────────────────────────────┘
                                    │
┌─────────────────────────────────────────────────────────────────┐
│                      Signal & Sentiment Tables                  │
├─────────────────────────────────────────────────────────────────┤
│  signal_alerts          │  sentiment_events       │  ticks       │
│  • Trading signals      │  • Raw news data        │  • Price     │
│  • Alert management     │  • Sentiment scores     │    ticks     │
│  • Strategy data        │  • Source tracking      │  • Real-time │
│                         │                         │    data      │
│                         │  sentiment_aggregates   │              │
│                         │  • Time-windowed data   │              │
│                         │  • Z-score calculations │              │
└─────────────────────────────────────────────────────────────────┘
                                    │
┌─────────────────────────────────────────────────────────────────┐
│                        GoodJob Tables                           │
├─────────────────────────────────────────────────────────────────┤
│  good_jobs              │  good_job_executions    │  good_job_*  │
│  • Job queue            │  • Execution tracking   │  • Batches   │
│  • Scheduling           │  • Performance metrics  │  • Settings  │
│  • Cron jobs            │  • Error handling       │  • Processes │
└─────────────────────────────────────────────────────────────────┘
```

## Core Tables

### 1. trading_pairs

**Purpose**: Stores metadata for all trading pairs and futures contracts.

**Schema**:
```sql
CREATE TABLE trading_pairs (
  id BIGSERIAL PRIMARY KEY,
  product_id VARCHAR NOT NULL UNIQUE,           -- e.g., "BTC-USD", "BIT-29AUG25-CDE"
  base_currency VARCHAR,                        -- e.g., "BTC", "ETH"
  quote_currency VARCHAR,                       -- e.g., "USD"
  status VARCHAR,                               -- e.g., "online", "offline"
  min_size DECIMAL(20,10),                      -- Minimum order size
  price_increment DECIMAL(20,10),               -- Price tick size
  size_increment DECIMAL(20,10),                -- Size increment
  enabled BOOLEAN DEFAULT TRUE NOT NULL,        -- Trading enabled flag
  contract_type VARCHAR,                        -- e.g., "CDE" (for futures)
  expiration_date DATE,                         -- Contract expiration
  created_at TIMESTAMP NOT NULL,
  updated_at TIMESTAMP NOT NULL
);

-- Indexes
CREATE UNIQUE INDEX index_trading_pairs_on_product_id ON trading_pairs(product_id);
CREATE INDEX index_trading_pairs_on_expiration_date ON trading_pairs(expiration_date);
```

**Key Features**:
- **Futures Contract Support**: Handles contract expiration and rollover
- **Product Metadata**: Stores trading constraints and specifications
- **Contract Parsing**: Automatic parsing of futures contract information
- **Expiration Tracking**: Built-in expiration date management

**Model Scopes**:
```ruby
TradingPair.enabled                    # Active trading pairs
TradingPair.current_month             # Current month contracts
TradingPair.upcoming_month            # Next month contracts
TradingPair.not_expired               # Non-expired contracts
TradingPair.active                    # Enabled and not expired
TradingPair.tradeable                 # Safe to trade (not expiring soon)
```

**Example Records**:
```sql
INSERT INTO trading_pairs VALUES
(1, 'BTC-USD', 'BTC', 'USD', 'online', 0.00001, 0.01, 0.00001, true, NULL, NULL),
(2, 'BIT-29AUG25-CDE', 'BTC', 'USD', 'online', 1, 0.01, 1, true, 'CDE', '2025-08-29');
```

### 2. positions

**Purpose**: Tracks active and historical trading positions for both day trading and swing trading.

**Schema**:
```sql
CREATE TABLE positions (
  id BIGSERIAL PRIMARY KEY,
  product_id VARCHAR,                           -- Trading pair ID
  side VARCHAR,                                 -- "LONG" or "SHORT"
  size DECIMAL,                                 -- Position size
  entry_price DECIMAL,                          -- Entry price
  entry_time TIMESTAMP,                         -- Position open time
  close_time TIMESTAMP,                         -- Position close time
  status VARCHAR,                               -- "OPEN" or "CLOSED"
  pnl DECIMAL,                                  -- Realized P&L
  take_profit DECIMAL,                          -- Take profit price
  stop_loss DECIMAL,                            -- Stop loss price
  day_trading BOOLEAN,                          -- Day trading flag
  created_at TIMESTAMP NOT NULL,
  updated_at TIMESTAMP NOT NULL
);
```

**Key Features**:
- **Position Types**: Supports both day trading and swing trading
- **Risk Management**: Built-in stop loss and take profit tracking
- **P&L Tracking**: Automatic profit/loss calculations
- **Time-based Management**: Entry and close time tracking

**Model Validations**:
```ruby
validates :product_id, presence: true
validates :side, inclusion: { in: %w[LONG SHORT] }
validates :size, numericality: { greater_than: 0 }
validates :entry_price, numericality: { greater_than: 0 }
validates :status, inclusion: { in: %w[OPEN CLOSED] }
validates :day_trading, inclusion: { in: [true, false] }
```

**Model Scopes**:
```ruby
Position.open                         # Open positions
Position.closed                       # Closed positions
Position.day_trading                  # Day trading positions
Position.swing_trading                # Swing trading positions
Position.by_product(product_id)       # Filter by product
Position.by_side(side)                # Filter by side
Position.opened_today                 # Positions opened today
Position.expiring_soon                # Day trading positions from yesterday
```

**Example Usage**:
```ruby
# Create new day trading position
Position.create!(
  product_id: "BTC-USD",
  side: "LONG",
  size: 2.0,
  entry_price: 45000.00,
  entry_time: Time.current,
  status: "OPEN",
  take_profit: 45800.00,
  stop_loss: 44500.00,
  day_trading: true
)

# Query open positions
open_positions = Position.open.day_trading.by_product("BTC-USD")
```

### 3. candles

**Purpose**: Stores OHLCV (Open, High, Low, Close, Volume) price data for multiple timeframes.

**Schema**:
```sql
CREATE TABLE candles (
  id BIGSERIAL PRIMARY KEY,
  symbol VARCHAR NOT NULL,                      -- Trading symbol
  timeframe VARCHAR DEFAULT '1h' NOT NULL,      -- Time interval
  timestamp TIMESTAMP NOT NULL,                 -- Candle timestamp
  open DECIMAL(20,10) NOT NULL,                 -- Opening price
  high DECIMAL(20,10) NOT NULL,                 -- Highest price
  low DECIMAL(20,10) NOT NULL,                  -- Lowest price
  close DECIMAL(20,10) NOT NULL,                -- Closing price
  volume DECIMAL(30,10) DEFAULT 0.0 NOT NULL,   -- Trading volume
  created_at TIMESTAMP NOT NULL,
  updated_at TIMESTAMP NOT NULL
);

-- Unique constraint prevents duplicate candles
CREATE UNIQUE INDEX index_candles_on_symbol_and_timeframe_and_timestamp 
ON candles(symbol, timeframe, timestamp);
```

**Supported Timeframes**:
- **1m**: 1-minute candles for precise entry timing
- **5m**: 5-minute candles for day trading signals
- **15m**: 15-minute candles for trend confirmation
- **1h**: 1-hour candles for trend analysis
- **6h**: 6-hour candles for longer-term context
- **1d**: Daily candles for swing trading

**Model Validations**:
```ruby
validates :symbol, :timestamp, presence: true
validates :timeframe, inclusion: { in: %w[1m 5m 15m 1h 6h 1d] }
validates :timestamp, uniqueness: { scope: [:symbol, :timeframe] }
```

**Model Scopes**:
```ruby
Candle.for_symbol("BTC-USD")          # Candles for specific symbol
Candle.one_minute                     # 1-minute candles
Candle.five_minute                    # 5-minute candles
Candle.fifteen_minute                 # 15-minute candles
Candle.hourly                         # 1-hour candles
```

**Query Examples**:
```ruby
# Get recent 1-hour BTC candles for strategy analysis
btc_candles = Candle.for_symbol("BTC-USD")
  .hourly
  .order(:timestamp)
  .last(50)

# Get 5-minute candles for the last 4 hours
recent_5m = Candle.for_symbol("BTC-USD")
  .five_minute
  .where("timestamp >= ?", 4.hours.ago)
  .order(:timestamp)
```

### 4. signal_alerts

**Purpose**: Stores trading signals generated by strategy algorithms with comprehensive metadata.

**Schema**:
```sql
CREATE TABLE signal_alerts (
  id BIGSERIAL PRIMARY KEY,
  symbol VARCHAR,                               -- Trading symbol
  side VARCHAR,                                 -- Signal direction
  signal_type VARCHAR,                          -- Signal type
  strategy_name VARCHAR,                        -- Strategy that generated signal
  confidence DECIMAL,                           -- Signal confidence (0-100)
  entry_price DECIMAL,                          -- Suggested entry price
  stop_loss DECIMAL,                            -- Stop loss price
  take_profit DECIMAL,                          -- Take profit price
  quantity INTEGER,                             -- Suggested quantity
  timeframe VARCHAR,                            -- Signal timeframe
  alert_status VARCHAR,                         -- Alert status
  alert_timestamp TIMESTAMP,                    -- When signal was generated
  expires_at TIMESTAMP,                         -- Signal expiration time
  triggered_at TIMESTAMP,                       -- When signal was acted upon
  metadata JSONB,                               -- Additional signal data
  strategy_data JSONB,                          -- Strategy-specific data
  created_at TIMESTAMP NOT NULL,
  updated_at TIMESTAMP NOT NULL
);
```

**Signal Types**:
- **entry**: New position entry signal
- **exit**: Position exit signal
- **stop_loss**: Stop loss trigger
- **take_profit**: Take profit trigger

**Alert Statuses**:
- **active**: Signal is active and actionable
- **triggered**: Signal has been acted upon
- **expired**: Signal has expired without action
- **cancelled**: Signal has been manually cancelled

**Model Validations**:
```ruby
validates :symbol, :side, :signal_type, :strategy_name, :confidence, presence: true
validates :side, inclusion: { in: %w[long short buy sell unknown] }
validates :signal_type, inclusion: { in: %w[entry exit stop_loss take_profit] }
validates :confidence, numericality: { greater_than: 0, less_than_or_equal_to: 100 }
validates :timeframe, inclusion: { in: %w[1m 5m 15m 1h 6h 1d] }
```

**Model Scopes**:
```ruby
SignalAlert.active                    # Active signals
SignalAlert.triggered                 # Triggered signals
SignalAlert.expired                   # Expired signals
SignalAlert.for_symbol(symbol)        # Signals for specific symbol
SignalAlert.by_strategy(name)         # Signals by strategy
SignalAlert.high_confidence(70)       # High confidence signals
SignalAlert.recent(24)                # Recent signals (hours)
SignalAlert.entry_signals             # Entry signals only
```

**Example Signal Creation**:
```ruby
SignalAlert.create!(
  symbol: "BTC-USD",
  side: "long",
  signal_type: "entry",
  strategy_name: "multi_timeframe_signal",
  confidence: 85.5,
  entry_price: 45000.00,
  stop_loss: 44500.00,
  take_profit: 45800.00,
  quantity: 2,
  timeframe: "5m",
  alert_status: "active",
  alert_timestamp: Time.current,
  expires_at: 1.hour.from_now,
  metadata: {
    ema_trend: "bullish",
    sentiment_z_score: 1.2
  },
  strategy_data: {
    ema_1h_short: 21,
    ema_1h_long: 50,
    current_trend: "bullish"
  }
)
```

### 5. sentiment_events

**Purpose**: Stores raw sentiment data from news sources for analysis.

**Schema**:
```sql
CREATE TABLE sentiment_events (
  id BIGSERIAL PRIMARY KEY,
  source VARCHAR NOT NULL,                      -- News source
  symbol VARCHAR,                               -- Related symbol
  url VARCHAR,                                  -- Article URL
  title VARCHAR,                                -- Article title
  score DECIMAL(6,3),                           -- Sentiment score
  confidence DECIMAL(6,3),                      -- Score confidence
  published_at TIMESTAMP NOT NULL,              -- Publication time
  raw_text_hash VARCHAR NOT NULL,               -- Deduplication hash
  meta JSONB DEFAULT '{}' NOT NULL,             -- Additional metadata
  created_at TIMESTAMP NOT NULL,
  updated_at TIMESTAMP NOT NULL
);

-- Indexes
CREATE INDEX index_sentiment_events_on_published_at ON sentiment_events(published_at);
CREATE INDEX index_sentiment_events_on_symbol ON sentiment_events(symbol);
CREATE UNIQUE INDEX index_sentiment_events_on_source_and_raw_text_hash 
ON sentiment_events(source, raw_text_hash);
```

**Model Features**:
- **Deduplication**: Prevents duplicate news articles
- **Multi-source Support**: Handles various news sources
- **Sentiment Scoring**: Stores calculated sentiment scores
- **Metadata Storage**: Flexible JSONB metadata field

**Model Scopes**:
```ruby
SentimentEvent.for_symbol("BTC")      # Events for specific symbol
SentimentEvent.recent(1.hour.ago)    # Recent events
SentimentEvent.unscored               # Events without sentiment scores
```

### 6. sentiment_aggregates

**Purpose**: Time-windowed aggregations of sentiment data for strategy use.

**Schema**:
```sql
CREATE TABLE sentiment_aggregates (
  id BIGSERIAL PRIMARY KEY,
  symbol VARCHAR NOT NULL,                      -- Trading symbol
  window VARCHAR NOT NULL,                      -- Time window
  window_end_at TIMESTAMP NOT NULL,             -- Window end time
  count INTEGER DEFAULT 0 NOT NULL,             -- Number of events
  avg_score DECIMAL(8,4) DEFAULT 0.0 NOT NULL,  -- Average sentiment
  weighted_score DECIMAL(8,4) DEFAULT 0.0 NOT NULL, -- Weighted sentiment
  z_score DECIMAL(8,4) DEFAULT 0.0 NOT NULL,    -- Normalized z-score
  meta JSONB DEFAULT '{}' NOT NULL,             -- Additional data
  created_at TIMESTAMP NOT NULL,
  updated_at TIMESTAMP NOT NULL
);

-- Unique constraint for time windows
CREATE UNIQUE INDEX index_sentiment_aggregates_on_sym_win_end 
ON sentiment_aggregates(symbol, window, window_end_at);
```

**Time Windows**:
- **15m**: Short-term sentiment for rapid signals
- **1h**: Intraday sentiment context
- **4h**: Medium-term sentiment trends
- **24h**: Daily sentiment baseline

**Usage in Trading**:
```ruby
# Get latest sentiment for BTC
sentiment = SentimentAggregate
  .where(symbol: "BTC", window: "15m")
  .order(window_end_at: :desc)
  .first

# Use z-score for signal filtering
if sentiment.z_score.abs > 1.2
  # High sentiment - proceed with signal
else
  # Neutral sentiment - filter out signal
end
```

### 7. ticks

**Purpose**: Stores real-time price tick data for backtesting and analysis.

**Schema**:
```sql
CREATE TABLE ticks (
  id BIGSERIAL PRIMARY KEY,
  product_id VARCHAR NOT NULL,                  -- Trading pair
  price DECIMAL(15,5) NOT NULL,                 -- Tick price
  observed_at TIMESTAMP NOT NULL,               -- Observation time
  created_at TIMESTAMP NOT NULL,
  updated_at TIMESTAMP NOT NULL
);

-- Index for efficient time-series queries
CREATE INDEX index_ticks_on_product_id_and_observed_at 
ON ticks(product_id, observed_at);
```

**Model Features**:
- **High Precision**: Stores prices with 5 decimal places
- **Time-series Optimized**: Indexed for efficient time-based queries
- **Real-time Data**: Used for backtesting and real-time candle aggregation

## GoodJob Tables

The system uses **GoodJob** for background job processing, which creates several tables:

### good_jobs
- **Purpose**: Main job queue and execution tracking
- **Key Fields**: `job_class`, `queue_name`, `scheduled_at`, `performed_at`, `cron_key`

### good_job_executions
- **Purpose**: Detailed job execution history
- **Key Fields**: `active_job_id`, `duration`, `error`, `finished_at`

### good_job_batches
- **Purpose**: Batch job management
- **Key Fields**: `description`, `serialized_properties`, `jobs_finished_at`

### good_job_processes
- **Purpose**: Worker process tracking
- **Key Fields**: `state`, `lock_type`

### good_job_settings
- **Purpose**: Job system configuration
- **Key Fields**: `key`, `value`

## Database Relationships

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│  trading_pairs  │───▶│   positions     │    │     candles     │
│  • product_id   │    │  • product_id   │    │  • symbol       │
│  • metadata     │    │  • size, price  │    │  • OHLCV data   │
└─────────────────┘    └─────────────────┘    └─────────────────┘
         │                       │
         ▼                       ▼
┌─────────────────┐    ┌─────────────────┐
│  signal_alerts  │    │      ticks      │
│  • symbol       │    │  • product_id   │
│  • strategy     │    │  • price        │
└─────────────────┘    └─────────────────┘

┌─────────────────┐    ┌─────────────────┐
│sentiment_events │───▶│sentiment_aggreg │
│  • raw data     │    │  • time windows │
│  • scores       │    │  • z-scores     │
└─────────────────┘    └─────────────────┘
```

**Key Relationships**:

1. **TradingPair → Position**: One-to-many (optional)
   ```ruby
   # In Position model
   belongs_to :trading_pair, primary_key: :product_id, foreign_key: :product_id, optional: true
   ```

2. **TradingPair → SignalAlert**: One-to-many (optional)
   ```ruby
   # In SignalAlert model
   belongs_to :trading_pair, foreign_key: :symbol, primary_key: :product_id, optional: true
   ```

3. **SentimentEvent → SentimentAggregate**: One-to-many (via aggregation jobs)

## Database Configuration

### Connection Settings
```ruby
# config/database.yml
default: &default
  adapter: postgresql
  encoding: unicode
  pool: <%= ENV.fetch("RAILS_MAX_THREADS") { 5 } %>
  url: <%= ENV["DATABASE_URL"] %>

development:
  <<: *default
  database: coinbase_futures_bot_development

test:
  <<: *default
  database: coinbase_futures_bot_test

production:
  <<: *default
  database: coinbase_futures_bot_production
```

### Performance Optimizations

#### Indexes
```sql
-- Time-series queries
CREATE INDEX index_candles_on_symbol_and_timeframe_and_timestamp;
CREATE INDEX index_ticks_on_product_id_and_observed_at;
CREATE INDEX index_sentiment_events_on_published_at;

-- Trading queries
CREATE INDEX index_positions_on_status_and_day_trading;
CREATE INDEX index_signal_alerts_on_alert_status_and_confidence;

-- Unique constraints
CREATE UNIQUE INDEX index_trading_pairs_on_product_id;
CREATE UNIQUE INDEX index_sentiment_events_on_source_and_raw_text_hash;
```

#### Query Optimization
```ruby
# Efficient candle queries with proper indexing
candles = Candle.for_symbol("BTC-USD")
  .hourly
  .where("timestamp >= ?", 1.day.ago)
  .order(:timestamp)

# Optimized position queries
positions = Position.includes(:trading_pair)
  .open
  .day_trading
  .where("entry_time >= ?", Date.current.beginning_of_day)
```

## Data Integrity

### Validations
- **Presence Validations**: All critical fields require values
- **Format Validations**: Symbol formats, price ranges, status values
- **Uniqueness Constraints**: Prevent duplicate records
- **Referential Integrity**: Foreign key relationships where appropriate

### Error Handling
```ruby
# Model-level error tracking with Sentry
class Position < ApplicationRecord
  include SentryTrackable
  
  after_create :log_position_opened
  after_update :log_position_updated
  
  private
  
  def log_position_opened
    Rails.logger.info("Position opened: #{product_id} #{side} #{size}")
  end
end
```

## Migration Examples

### Adding New Timeframe Support
```ruby
class AddNewTimeframeToCandles < ActiveRecord::Migration[8.0]
  def change
    # Update timeframe validation
    reversible do |dir|
      dir.up do
        execute <<-SQL
          ALTER TABLE candles 
          DROP CONSTRAINT IF EXISTS candles_timeframe_check;
          
          ALTER TABLE candles 
          ADD CONSTRAINT candles_timeframe_check 
          CHECK (timeframe IN ('1m', '5m', '15m', '1h', '6h', '1d', '3m'));
        SQL
      end
      
      dir.down do
        execute <<-SQL
          ALTER TABLE candles 
          DROP CONSTRAINT candles_timeframe_check;
          
          ALTER TABLE candles 
          ADD CONSTRAINT candles_timeframe_check 
          CHECK (timeframe IN ('1m', '5m', '15m', '1h', '6h', '1d'));
        SQL
      end
    end
  end
end
```

### Adding Position Metadata
```ruby
class AddMetadataToPositions < ActiveRecord::Migration[8.0]
  def change
    add_column :positions, :metadata, :jsonb, default: {}
    add_column :positions, :strategy_name, :string
    add_column :positions, :signal_id, :bigint
    
    add_index :positions, :strategy_name
    add_index :positions, :signal_id
    add_index :positions, :metadata, using: :gin
  end
end
```

## Backup and Recovery

### Automated Backups
```bash
# Daily backup script
#!/bin/bash
BACKUP_DIR="/backups/$(date +%Y-%m-%d)"
mkdir -p "$BACKUP_DIR"

pg_dump "$DATABASE_URL" | gzip > "$BACKUP_DIR/database.sql.gz"

# Keep only last 30 days
find /backups -type d -mtime +30 -exec rm -rf {} \;
```

### Point-in-Time Recovery
```bash
# Restore from specific backup
gunzip -c /backups/2025-01-18/database.sql.gz | psql "$DATABASE_URL"

# Restore specific tables
pg_restore -t candles -t positions backup.dump
```

## Monitoring and Maintenance

### Database Health Checks
```ruby
# In HealthCheckJob
def check_database_health
  {
    connection_pool: {
      size: ActiveRecord::Base.connection_pool.size,
      checked_out: ActiveRecord::Base.connection_pool.checked_out.size,
      available: ActiveRecord::Base.connection_pool.available.size
    },
    recent_activity: {
      candles_today: Candle.where("created_at >= ?", Date.current).count,
      signals_today: SignalAlert.where("created_at >= ?", Date.current).count,
      positions_open: Position.open.count
    }
  }
end
```

### Performance Monitoring
```sql
-- Query performance analysis
SELECT 
  query,
  calls,
  total_time,
  mean_time,
  rows
FROM pg_stat_statements 
ORDER BY total_time DESC 
LIMIT 10;

-- Index usage statistics
SELECT 
  schemaname,
  tablename,
  indexname,
  idx_scan,
  idx_tup_read,
  idx_tup_fetch
FROM pg_stat_user_indexes 
ORDER BY idx_scan DESC;
```

---

**Next**: [Getting Started](Getting-Started) | **Previous**: [API Reference](API-Reference) | **Up**: [Home](Home)