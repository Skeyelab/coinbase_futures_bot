# Architecture Overview

## System Architecture

The coinbase_futures_bot is a Rails 8.0 API-only application designed for automated cryptocurrency futures trading. The system follows a modular architecture with clear separation of concerns.

```
┌─────────────────────────────────────────────────────────────────┐
│                        Application Layer                         │
├─────────────────────────────────────────────────────────────────┤
│  Rails Controllers (API Endpoints)                              │
│  • PositionsController - Position management UI                 │
│  • SentimentController - Sentiment analysis API                 │
│  • Health checks (/up)                                          │
└─────────────────────────────────────────────────────────────────┘
                                    │
┌─────────────────────────────────────────────────────────────────┐
│                        Service Layer                            │
├─────────────────────────────────────────────────────────────────┤
│  Market Data Services                                           │
│  • CoinbaseSpotSubscriber - WebSocket spot data                │
│  • CoinbaseFuturesSubscriber - WebSocket futures data          │
│  • CoinbaseRest - REST API client                              │
│  • FuturesContractManager - Contract lifecycle management      │
│                                                                 │
│  Trading Services                                               │
│  • CoinbasePositions - Position management                     │
│  • FuturesExecutor - Order execution and risk management       │
│                                                                 │
│  Strategy Services                                              │
│  • MultiTimeframeSignal - Main trading strategy                │
│  • SpotDrivenStrategy - Spot-based signal generation           │
│  • PaperTrading::ExchangeSimulator - Backtesting engine        │
│                                                                 │
│  External API Clients                                           │
│  • Coinbase::AdvancedTradeClient - Futures trading API         │
│  • Coinbase::ExchangeClient - Spot trading API                 │
│  • Sentiment::CryptoPanicClient - News sentiment data          │
└─────────────────────────────────────────────────────────────────┘
                                    │
┌─────────────────────────────────────────────────────────────────┐
│                      Background Jobs Layer                      │
├─────────────────────────────────────────────────────────────────┤
│  Data Ingestion Jobs                                            │
│  • FetchCandlesJob - OHLCV candle data collection              │
│  • MarketDataSubscribeJob - Real-time market data streams      │
│  • FetchCryptopanicJob - News sentiment data collection        │
│                                                                 │
│  Signal Generation Jobs                                         │
│  • GenerateSignalsJob - Trading signal generation              │
│  • CalibrationJob - Strategy parameter optimization            │
│                                                                 │
│  Sentiment Analysis Jobs                                        │
│  • ScoreSentimentJob - Sentiment scoring for news events       │
│  • AggregateSentimentJob - Rolling sentiment aggregations      │
│                                                                 │
│  Trading Jobs                                                   │
│  • PaperTradingJob - Automated paper trading execution         │
└─────────────────────────────────────────────────────────────────┘
                                    │
┌─────────────────────────────────────────────────────────────────┐
│                        Data Layer                               │
├─────────────────────────────────────────────────────────────────┤
│  Core Models                                                    │
│  • TradingPair - Trading instruments and contract metadata     │
│  • Candle - OHLCV price data                                   │
│  • Tick - Real-time price ticks                                │
│                                                                 │
│  Sentiment Models                                               │
│  • SentimentEvent - Raw sentiment events from news sources     │
│  • SentimentAggregate - Processed sentiment metrics            │
│                                                                 │
│  Job Management (GoodJob)                                       │
│  • good_jobs - Job queue and execution tracking                │
│  • good_job_* - Job metadata and batch processing              │
└─────────────────────────────────────────────────────────────────┘
                                    │
┌─────────────────────────────────────────────────────────────────┐
│                      External Systems                           │
├─────────────────────────────────────────────────────────────────┤
│  Coinbase APIs                                                 │
│  • Advanced Trade API - Futures trading                        │
│  • Exchange API - Spot market data                             │
│                                                                 │
│  News Sources                                                   │
│  • CryptoPanic API - Cryptocurrency news aggregation           │
│                                                                 │
│  Infrastructure                                                 │
│  • PostgreSQL - Primary database                               │
│  • WebSocket connections - Real-time data streams              │
└─────────────────────────────────────────────────────────────────┘
```

## Data Flow

### 1. Market Data Ingestion
1. **Real-time Data**: WebSocket subscribers connect to Coinbase streams
2. **Historical Data**: REST API fetches OHLCV candles on schedule
3. **Storage**: Raw ticks and processed candles stored in PostgreSQL
4. **Processing**: Data normalized and stored in unified schema

### 2. Sentiment Analysis Pipeline
1. **Collection**: FetchCryptopanicJob retrieves news articles
2. **Scoring**: ScoreSentimentJob applies lexicon-based sentiment scoring
3. **Aggregation**: AggregateSentimentJob creates rolling time-window summaries
4. **Z-Score Calculation**: Statistical normalization for signal generation

### 3. Signal Generation
1. **Multi-Timeframe Analysis**: 1h trend, 15m confirmation, 5m entry triggers
2. **Sentiment Gating**: Signals filtered by sentiment z-score thresholds
3. **Risk Management**: Position sizing based on volatility and equity
4. **Contract Resolution**: Automatic rollover to current month contracts

### 4. Execution Pipeline
1. **Signal Processing**: GenerateSignalsJob produces trading signals
2. **Risk Validation**: FuturesExecutor applies risk controls
3. **Order Placement**: Integration with Coinbase Advanced Trade API
4. **Position Monitoring**: Continuous tracking and adjustment

## Component Interactions

### Market Data Flow
```
Coinbase WebSocket → Subscriber Services → Database Models → Strategy Services
```

### Trading Flow
```
Strategy Services → Signal Generation → Risk Management → Order Execution → Position Tracking
```

### Sentiment Flow
```
News APIs → Sentiment Events → Scoring → Aggregation → Signal Filtering
```

## Key Design Principles

### 1. Event-Driven Architecture
- Background jobs handle asynchronous processing
- GoodJob provides reliable job scheduling and execution
- WebSocket subscribers for real-time data ingestion

### 2. Service-Oriented Design
- Clear separation between market data, trading, and strategy services
- Each service has a single responsibility
- Dependency injection for testability

### 3. Data Consistency
- PostgreSQL ensures ACID compliance
- Unique constraints prevent duplicate data
- Proper indexing for query performance

### 4. Risk Management
- Multiple layers of risk controls
- Basis threshold checks for futures entries
- Position sizing based on equity and volatility

### 5. Observability
- Comprehensive logging throughout the system
- Health check endpoints for monitoring
- GoodJob dashboard for job monitoring

## Technology Stack

### Core Framework
- **Rails 8.0.x**: API-only application framework
- **Ruby 3.2.2**: Programming language
- **PostgreSQL**: Primary database

### Background Processing
- **GoodJob**: Background job processing with PostgreSQL backend
- **ActiveJob**: Rails job interface
- **Cron scheduling**: Built-in job scheduling

### External Integrations
- **Coinbase Advanced Trade API**: Futures trading
- **Coinbase Exchange API**: Spot market data
- **CryptoPanic API**: News sentiment data
- **WebSocket connections**: Real-time data streams

### Development & Testing
- **RSpec**: Testing framework
- **VCR**: HTTP interaction recording for tests
- **Brakeman**: Security scanning
- **RuboCop**: Code style enforcement

## Scalability Considerations

### Database Performance
- Proper indexing on time-series data
- Partitioning strategies for large datasets
- Connection pooling for concurrent access

### Job Processing
- Horizontal scaling with multiple GoodJob workers
- Queue isolation for different job types
- Retry strategies for failed jobs

### API Rate Limiting
- Built-in rate limiting for external API calls
- Exponential backoff for failed requests
- Circuit breaker patterns for service protection

## Security

### API Authentication
- JWT-based authentication for Coinbase APIs
- Secure credential storage (environment variables)
- API key rotation support

### Data Protection
- No sensitive data in logs
- Environment-based configuration
- Secure WebSocket connections (WSS)

### Code Security
- Regular Brakeman security scans
- Dependency vulnerability monitoring
- Secure deployment practices

## Important Notes

**Current Month Futures Only**: The project exclusively handles current month futures contracts (e.g., BIT-29AUG25-CDE, ET-29AUG25-CDE). Perpetual contracts are not supported. The system includes automatic contract discovery, rollover management, and expiration handling for monthly futures.
