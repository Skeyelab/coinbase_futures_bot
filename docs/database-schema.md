# Database Schema Documentation

## Overview

The application uses PostgreSQL as the primary database with a focus on time-series data for financial information. The schema is designed to support real-time trading operations, sentiment analysis, and background job processing.

## Entity Relationship Diagram

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   trading_pairs │    │     candles     │    │      ticks      │
├─────────────────┤    ├─────────────────┤    ├─────────────────┤
│ id (PK)         │    │ id (PK)         │    │ id (PK)         │
│ product_id (UK) │◄──┤│ symbol          │    │ product_id      │
│ base_currency   │    │ timeframe       │    │ price           │
│ quote_currency  │    │ timestamp       │    │ observed_at     │
│ contract_type   │    │ open, high, low │    │ created_at      │
│ expiration_date │    │ close, volume   │    │ updated_at      │
│ status          │    │ created_at      │    └─────────────────┘
│ min_size        │    │ updated_at      │
│ price_increment │    └─────────────────┘
│ size_increment  │
│ enabled         │
│ created_at      │
│ updated_at      │
└─────────────────┘

┌─────────────────┐    ┌─────────────────┐
│sentiment_events │    │sentiment_aggreg │
├─────────────────┤    ├─────────────────┤
│ id (PK)         │    │ id (PK)         │
│ source          │───┤│ symbol          │
│ symbol          │    │ window          │
│ url             │    │ window_end_at   │
│ title           │    │ count           │
│ score           │    │ avg_score       │
│ confidence      │    │ weighted_score  │
│ published_at    │    │ z_score         │
│ raw_text_hash   │    │ meta (jsonb)    │
│ meta (jsonb)    │    │ created_at      │
│ created_at      │    │ updated_at      │
│ updated_at      │    └─────────────────┘
└─────────────────┘

┌─────────────────┐
│   good_jobs     │ (GoodJob tables for background processing)
├─────────────────┤
│ id (PK)         │
│ queue_name      │
│ priority        │
│ serialized_params│
│ scheduled_at    │
│ performed_at    │
│ finished_at     │
│ error           │
│ ... (other GoodJob fields)
└─────────────────┘
```

## Core Tables

### trading_pairs

Stores metadata about trading instruments, including both spot and futures contracts.

| Column | Type | Description | Constraints |
|--------|------|-------------|-------------|
| id | bigint | Primary key | NOT NULL, AUTO_INCREMENT |
| product_id | string | Trading pair identifier (e.g., "BTC-USD", "BTC-29AUG25-CDE") | NOT NULL, UNIQUE |
| base_currency | string | Base currency symbol (e.g., "BTC") | |
| quote_currency | string | Quote currency symbol (e.g., "USD") | |
| contract_type | string | Contract type for futures (e.g., "CDE") | |
| expiration_date | date | Contract expiration date (futures only) | |
| status | string | Trading status | |
| min_size | decimal(20,10) | Minimum order size | |
| price_increment | decimal(20,10) | Minimum price increment | |
| size_increment | decimal(20,10) | Minimum size increment | |
| enabled | boolean | Whether trading is enabled | NOT NULL, DEFAULT true |
| created_at | timestamp | Record creation time | NOT NULL |
| updated_at | timestamp | Record update time | NOT NULL |

**Indexes:**
- `index_trading_pairs_on_product_id` (unique)
- `index_trading_pairs_on_expiration_date`

**Key Methods:**
- `current_month?` - Check if contract expires in current month
- `upcoming_month?` - Check if contract expires in next month
- `expired?` - Check if contract has expired
- `parse_contract_info` - Extract contract details from product_id

### candles

Stores OHLCV (Open, High, Low, Close, Volume) price data for technical analysis.

| Column | Type | Description | Constraints |
|--------|------|-------------|-------------|
| id | bigint | Primary key | NOT NULL, AUTO_INCREMENT |
| symbol | string | Trading pair symbol | NOT NULL |
| timeframe | string | Candle timeframe (1m, 5m, 15m, 1h, 6h, 1d) | NOT NULL, DEFAULT "1h" |
| timestamp | timestamp | Candle open time | NOT NULL |
| open | decimal(20,10) | Opening price | NOT NULL |
| high | decimal(20,10) | Highest price | NOT NULL |
| low | decimal(20,10) | Lowest price | NOT NULL |
| close | decimal(20,10) | Closing price | NOT NULL |
| volume | decimal(30,10) | Trading volume | NOT NULL, DEFAULT 0.0 |
| created_at | timestamp | Record creation time | NOT NULL |
| updated_at | timestamp | Record update time | NOT NULL |

**Indexes:**
- `index_candles_on_symbol_and_timeframe_and_timestamp` (unique composite)

**Scopes:**
- `for_symbol(symbol)` - Filter by symbol
- `one_minute`, `five_minute`, `fifteen_minute`, `hourly` - Filter by timeframe

### ticks

Stores real-time price tick data from WebSocket feeds.

| Column | Type | Description | Constraints |
|--------|------|-------------|-------------|
| id | bigint | Primary key | NOT NULL, AUTO_INCREMENT |
| product_id | string | Trading pair identifier | NOT NULL |
| price | decimal(15,5) | Tick price | NOT NULL |
| observed_at | timestamp | Time when price was observed | NOT NULL |
| created_at | timestamp | Record creation time | NOT NULL |
| updated_at | timestamp | Record update time | NOT NULL |

**Indexes:**
- `index_ticks_on_product_id_and_observed_at`

**Scopes:**
- `for_product(product_id)` - Filter by product
- `between(start_time, end_time)` - Filter by time range

## Sentiment Analysis Tables

### sentiment_events

Stores raw sentiment events from news sources.

| Column | Type | Description | Constraints |
|--------|------|-------------|-------------|
| id | bigint | Primary key | NOT NULL, AUTO_INCREMENT |
| source | string | News source (e.g., "cryptopanic") | NOT NULL |
| symbol | string | Related trading symbol | |
| url | string | Source URL | |
| title | string | Article title | |
| score | decimal(6,3) | Sentiment score (-1.0 to 1.0) | |
| confidence | decimal(6,3) | Confidence level (0.0 to 1.0) | |
| published_at | timestamp | Article publication time | NOT NULL |
| raw_text_hash | string | Hash of raw text content | NOT NULL |
| meta | jsonb | Additional metadata | NOT NULL, DEFAULT {} |
| created_at | timestamp | Record creation time | NOT NULL |
| updated_at | timestamp | Record update time | NOT NULL |

**Indexes:**
- `index_sentiment_events_on_source_and_raw_text_hash` (unique composite)
- `index_sentiment_events_on_symbol`
- `index_sentiment_events_on_url`
- `index_sentiment_events_on_published_at`

**Scopes:**
- `for_symbol(symbol)` - Filter by symbol
- `recent(since_time)` - Filter by publication time
- `unscored` - Events without sentiment scores

### sentiment_aggregates

Stores processed sentiment metrics in time windows.

| Column | Type | Description | Constraints |
|--------|------|-------------|-------------|
| id | bigint | Primary key | NOT NULL, AUTO_INCREMENT |
| symbol | string | Trading pair symbol | NOT NULL |
| window | string | Time window (5m, 15m, 1h) | NOT NULL |
| window_end_at | timestamp | End of time window | NOT NULL |
| count | integer | Number of events in window | NOT NULL, DEFAULT 0 |
| avg_score | decimal(8,4) | Average sentiment score | NOT NULL, DEFAULT 0.0 |
| weighted_score | decimal(8,4) | Confidence-weighted score | NOT NULL, DEFAULT 0.0 |
| z_score | decimal(8,4) | Normalized z-score | NOT NULL, DEFAULT 0.0 |
| meta | jsonb | Additional metadata | NOT NULL, DEFAULT {} |
| created_at | timestamp | Record creation time | NOT NULL |
| updated_at | timestamp | Record update time | NOT NULL |

**Indexes:**
- `index_sentiment_aggregates_on_sym_win_end` (unique composite)
- `index_sentiment_aggregates_on_symbol`
- `index_sentiment_aggregates_on_window_end_at`

## Background Job Tables (GoodJob)

### good_jobs

Main job queue table managed by GoodJob.

| Column | Type | Description |
|--------|------|-------------|
| id | uuid | Primary key |
| queue_name | text | Job queue name |
| priority | integer | Job priority |
| serialized_params | jsonb | Job parameters |
| scheduled_at | timestamp | When job should run |
| performed_at | timestamp | When job started |
| finished_at | timestamp | When job completed |
| error | text | Error message if failed |
| active_job_id | uuid | ActiveJob identifier |
| concurrency_key | text | Concurrency control |
| cron_key | text | Cron job identifier |
| cron_at | timestamp | Cron schedule time |

**Additional GoodJob Tables:**
- `good_job_executions` - Job execution history
- `good_job_processes` - Worker process tracking
- `good_job_batches` - Batch job management
- `good_job_settings` - Job configuration

## Migration History

Current schema version: `20250824052659`

### Key Migrations

1. **20250809042439_create_good_jobs.rb** - GoodJob setup
2. **20250811000001_create_candles.rb** - OHLCV data storage
3. **20250811000002_create_trading_pairs.rb** - Trading instruments
4. **20250811162000_create_ticks.rb** - Real-time price data
5. **20250823232103_create_sentiment_events.rb** - Sentiment analysis
6. **20250823232146_create_sentiment_aggregates.rb** - Sentiment metrics
7. **20250824052659_add_expiration_date_to_trading_pairs.rb** - Futures support

## Data Relationships

### Time-Series Data
- `candles` and `ticks` are linked to `trading_pairs` via `product_id`
- Time-based partitioning considerations for large datasets
- Proper indexing for time-range queries

### Sentiment Pipeline
- `sentiment_events` → `sentiment_aggregates` processing flow
- Z-score calculation uses rolling window statistics
- Sentiment filtering in trading strategies

### Contract Management
- `trading_pairs` tracks contract lifecycles
- Expiration date management for futures rollover
- Current/upcoming month contract resolution

## Performance Considerations

### Indexing Strategy
- Composite indexes for common query patterns
- Time-based indexes for historical data queries
- Symbol-based indexes for instrument filtering

### Data Retention
- Consider partitioning for time-series tables
- Implement data archival for old records
- Monitor disk usage growth

### Query Optimization
- Use appropriate indexes for time-range queries
- Batch inserts for high-frequency data
- Connection pooling for concurrent access

## Backup and Recovery

### Backup Strategy
- Regular PostgreSQL dumps
- Point-in-time recovery capability
- Test restore procedures

### Data Integrity
- Foreign key constraints where appropriate
- Unique constraints to prevent duplicates
- Validation at application level

### Monitoring
- Query performance monitoring
- Index usage analysis
- Database connection monitoring
