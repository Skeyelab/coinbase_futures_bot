# High-Frequency Trading System

## Overview

The coinbase_futures_bot now includes a comprehensive high-frequency job scheduling system designed for day trading operations. This system enables sub-minute processing intervals for market data updates, signal generation, and position management.

## Features Implemented

### 🚀 Sub-Minute Job Scheduling

- **30-second intervals**: Market data updates and position monitoring
- **15-second intervals**: Real-time P&L tracking
- **1-minute intervals**: 1-minute candle processing
- **5-minute intervals**: High-frequency signal generation

### 📊 High-Frequency Jobs

| Job | Frequency | Purpose |
|-----|-----------|---------|
| `HighFrequencyMarketDataJob` | 30s | Current price updates, order book metrics |
| `HighFrequency1mCandleJob` | 1m | 1-minute candle collection and processing |
| `HighFrequencyPnLTrackingJob` | 15s | Real-time P&L calculation and alerts |
| `HighFrequencyPositionMonitorJob` | 30s | Position risk monitoring and time limits |
| `HighFrequencySignalGenerationJob` | 5m | 1m/5m timeframe signal generation |

### 💡 Key Services

#### RealTimePnLService
- Continuous portfolio P&L calculation
- Position-level unrealized P&L tracking
- Risk metrics and performance analytics
- TP/SL trigger detection

#### HighFrequencyPerformanceMonitor
- System resource monitoring (CPU, memory, disk)
- Database performance tracking
- Job queue health monitoring
- Automated alerting for performance issues

#### Strategy::HighFrequencyDayTrading
- 1-minute and 5-minute EMA-based strategy
- Pullback entry detection
- Volume confirmation signals
- High-confidence immediate execution triggers

### 🏗️ Database Optimizations

#### High-Frequency Indexes
- `idx_positions_status_day_trading` - Fast position queries
- `idx_candles_hf_timeframes` - Optimized 1m/5m candle access
- `idx_trading_pairs_enabled_price_updated` - Current price lookups
- `idx_good_jobs_queue_priority_scheduled` - Job processing optimization

#### Real-Time Fields
- `trading_pairs.last_price` - Cached current prices
- `trading_pairs.last_price_updated_at` - Price freshness tracking
- `positions.unrealized_pnl` - Cached P&L values
- `positions.current_price` - Position-specific price cache

### ⚙️ Configuration

#### GoodJob Enhancements
```ruby
# High-frequency queue with 10 workers
config.good_job.queues = "default:5;critical:2;low:1;high_frequency:10"

# 1-second poll interval for responsiveness
config.good_job.poll_interval = 1

# Increased thread pool for concurrent processing
config.good_job.max_threads = 10

# Sub-minute cron scheduling support
cron: "*/30 * * * * *"  # Every 30 seconds
cron: "*/15 * * * * *"  # Every 15 seconds
```

## Usage

### Running Validation
```bash
# Comprehensive system validation
bin/rails high_frequency:validate

# Performance testing
bin/rails high_frequency:performance_test

# Real-time monitoring
bin/rails high_frequency:monitor

# Stress testing (development only)
bin/rails high_frequency:stress_test
```

### Monitoring Commands
```bash
# Check system health
curl http://localhost:3000/up

# View GoodJob dashboard (development)
open http://localhost:3000/good_job
```

## Performance Characteristics

### Execution Times (Tested)
- `HighFrequencyMarketDataJob`: ~1.8s
- `HighFrequency1mCandleJob`: ~78ms
- `HighFrequencyPnLTrackingJob`: ~713ms
- `HighFrequencyPositionMonitorJob`: ~633ms
- `HighFrequencySignalGenerationJob`: ~158ms

### System Requirements
- **Memory**: System optimized for <100MB additional usage
- **CPU**: Designed for <20% additional load
- **Database**: Optimized queries with <50ms execution time
- **Cache**: Redis recommended for production deployments

## Day Trading Integration

### Position Management
- Automatic 24-hour position closure enforcement
- Real-time TP/SL monitoring
- Emergency position closure capabilities
- Stale price data detection and alerts

### Risk Controls
- Position size limits based on equity
- Maximum drawdown monitoring
- Rapid position closure for risk events
- Real-time portfolio exposure tracking

### Signal Generation
- 1-minute EMA crossover detection
- 5-minute trend confirmation
- Volume spike identification
- Breakout pattern recognition

## Environment Variables

```bash
# High-frequency job scheduling
HF_MARKET_DATA_CRON="*/30 * * * * *"
HF_CANDLES_1M_CRON="0 * * * * *"
HF_PNL_TRACKING_CRON="*/15 * * * * *"
HF_POSITION_MONITOR_CRON="*/30 * * * * *"
HF_SIGNALS_5M_CRON="*/5 * * * *"

# Performance tuning
GOOD_JOB_MAX_THREADS=10
GOOD_JOB_POLL_INTERVAL=1
GOOD_JOB_MAX_CACHE=1000

# Trading parameters
HF_SIGNAL_EQUITY_USD=10000
BASE_EQUITY_USD=10000
```

## Alerting and Monitoring

### Performance Alerts
- Memory usage >85%
- CPU usage >80%
- Database query time >100ms
- Queue depth >100 jobs
- Job failure rate >10/hour

### Trading Alerts
- Stale price data detected
- Position time limit violations
- Large unrealized losses (>10%)
- TP/SL trigger failures

## Production Considerations

### Deployment
1. Enable Redis cache for optimal performance
2. Configure database connection pooling
3. Set up external monitoring (New Relic, DataDog)
4. Implement alerting integrations (Slack, email)
5. Enable logging aggregation

### Scaling
- Horizontal scaling supported via multiple worker processes
- Database read replicas recommended for high-frequency queries
- CDN recommended for static dashboard assets
- Load balancing for multiple application instances

### Security
- API rate limiting for external calls
- Database query timeout enforcement
- Job execution timeout limits
- Memory usage monitoring and limits

## Testing

The system includes comprehensive testing tools:

- **Validation Suite**: Checks configuration, database, jobs, and performance
- **Performance Tests**: Measures execution times and resource usage
- **Stress Tests**: Validates system under high load
- **Monitoring Tools**: Real-time system health visibility

All tests are designed to ensure the system meets the demanding requirements of high-frequency day trading operations while maintaining system stability and performance.

## Future Enhancements

- WebSocket integration for real-time market data
- Machine learning signal enhancement
- Advanced risk management algorithms
- Multi-exchange arbitrage capabilities
- Automated strategy optimization