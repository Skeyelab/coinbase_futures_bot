# Architecture Overview

## System Architecture

The coinbase_futures_bot is a Rails 8.0 API-only application designed for automated cryptocurrency futures trading. The system follows a modular architecture with clear separation of concerns optimized for **day trading** operations.

## High-Level Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                        Application Layer                         │
├─────────────────────────────────────────────────────────────────┤
│  Rails Controllers (API Endpoints)                              │
│  • PositionsController - Position management UI                 │
│  • SignalController - Real-time trading signals API            │
│  • SentimentController - Sentiment analysis API                 │
│  • SlackController - Slack bot integration                     │
│  • ChatBotCLI - AI-powered command line interface             │
│  • Health checks (/up, /health)                                │
└─────────────────────────────────────────────────────────────────┘
                                    │
┌─────────────────────────────────────────────────────────────────┐
│                        Service Layer                            │
├─────────────────────────────────────────────────────────────────┤
│  AI Chat Interface Services (3 services)                       │
│  • ChatBotService - Main chat orchestrator                     │
│  • AiCommandProcessorService - AI provider integration         │
│  • ChatAuditLogger - Security & compliance logging            │
│                                                                 │
│  Market Data Services (6 services)                             │
│  • CoinbaseSpotSubscriber - WebSocket spot data                │
│  • CoinbaseFuturesSubscriber - WebSocket futures data          │
│  • CoinbaseRest - REST API client                              │
│  • FuturesContractManager - Contract lifecycle management      │
│  • RealTimeCandleAggregator - Live candle updates              │
│                                                                 │
│  Trading Services (4 services)                                 │
│  • CoinbasePositions - Position management                     │
│  • FuturesExecutor - Order execution and risk management       │
│  • DayTradingPositionManager - Intraday position logic         │
│  • SwingPositionManager - Multi-day position logic             │
│                                                                 │
│  Strategy Services (3 services)                                │
│  • MultiTimeframeSignal - Main trading strategy                │
│  • SpotDrivenStrategy - Spot-based signal generation           │
│  • PullbackStrategy - Pullback entry strategy                  │
│                                                                 │
│  External API Clients (3 services)                             │
│  • Coinbase::AdvancedTradeClient - Futures trading API         │
│  • Coinbase::ExchangeClient - Spot trading API                 │
│  • Sentiment::CryptoPanicClient - News sentiment data          │
│                                                                 │
│  Support Services (22 services)                                │
│  • Paper Trading, Sentiment Analysis, AI Chat Bot, etc.        │
└─────────────────────────────────────────────────────────────────┘
                                    │
┌─────────────────────────────────────────────────────────────────┐
│                      Background Jobs Layer                      │
├─────────────────────────────────────────────────────────────────┤
│  Data Ingestion Jobs (4 jobs)                                  │
│  • FetchCandlesJob - OHLCV candle data collection              │
│  • FetchCryptopanicJob - News data collection                  │
│  • MarketDataSubscribeJob - WebSocket management               │
│  • FetchNewsJob - Multi-source news aggregation               │
│                                                                 │
│  Signal Processing Jobs (4 jobs)                               │
│  • GenerateSignalsJob - Main signal generation                 │
│  • RapidSignalEvaluationJob - High-frequency evaluation        │
│  • RealTimeSignalJob - Live signal processing                  │
│  • RealTimeMonitoringJob - Signal monitoring                   │
│                                                                 │
│  Sentiment Analysis Jobs (3 jobs)                              │
│  • ScoreSentimentJob - Sentiment scoring                       │
│  • AggregateSentimentJob - Time-window aggregation             │
│  • FetchNewsJob - News source integration                      │
│                                                                 │
│  Position Management Jobs (6 jobs)                             │
│  • DayTradingPositionManagementJob - Intraday management       │
│  • SwingPositionManagementJob - Multi-day management           │
│  • EndOfDayPositionClosureJob - Day trading cleanup            │
│  • PositionCloseJob - Position closure execution               │
│  • SwingPositionCleanupJob - Swing position cleanup            │
│  • SwingRiskMonitoringJob - Overnight risk monitoring          │
│                                                                 │
│  Risk & Monitoring Jobs (8 jobs)                               │
│  • ContractExpiryMonitoringJob - Contract rollover             │
│  • FuturesBasisMonitoringJob - Basis tracking                  │
│  • MarginWindowMonitoringJob - Margin monitoring               │
│  • ArbitrageOpportunityJob - Cross-market opportunities        │
│  • HealthCheckJob - System health monitoring                   │
│  • CalibrationJob - Strategy parameter tuning                  │
│  • PaperTradingJob - Simulation execution                      │
│  • TestJob - Development testing                               │
└─────────────────────────────────────────────────────────────────┘
                                    │
┌─────────────────────────────────────────────────────────────────┐
│                        Data Layer                               │
├─────────────────────────────────────────────────────────────────┤
│  Core Trading Models                                            │
│  • TradingPair - Product metadata and configuration            │
│  • Position - Active and historical positions                  │
│  • SignalAlert - Trading signals and alerts                    │
│                                                                 │
│  Market Data Models                                             │
│  • Candle - OHLCV price data (1m, 5m, 15m, 1h, 1d)           │
│  • Tick - Real-time price ticks                                │
│                                                                 │
│  Sentiment Models                                               │
│  • SentimentEvent - Raw sentiment events from news sources     │
│  • SentimentAggregate - Processed sentiment metrics            │
│                                                                 │
│  Chat Interface Models                                          │
│  • ChatSession - Persistent conversation sessions              │
│  • ChatMessage - Individual messages with profit scoring       │
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
│  • CoinDesk RSS - Financial news                               │
│  • CoinTelegraph RSS - Crypto news                             │
│                                                                 │
│  AI Services                                                    │
│  • OpenRouter API - Primary AI provider (Claude 3.5 Sonnet)   │
│  • OpenAI API - Fallback AI provider (GPT-4)                   │
│                                                                 │
│  Infrastructure                                                 │
│  • PostgreSQL - Primary database                               │
│  • WebSocket connections - Real-time data streams              │
│  • Slack API - Notifications and bot commands                  │
│  • Sentry - Error monitoring and performance tracking          │
└─────────────────────────────────────────────────────────────────┘
```

## Data Flow Architecture

### 1. Market Data Ingestion Pipeline

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│  Coinbase APIs │───▶│  Data Services  │───▶│   Database      │
│  • Spot WS      │    │  • Subscribers  │    │  • Candles      │
│  • Futures WS   │    │  • REST Client  │    │  • Ticks        │
│  • REST API     │    │  • Normalizers  │    │  • TradingPairs │
└─────────────────┘    └─────────────────┘    └─────────────────┘
                                │
                       ┌─────────────────┐
                       │  Real-time      │
                       │  Aggregation    │
                       │  • 1m candles   │
                       │  • 5m candles   │
                       │  • Live updates │
                       └─────────────────┘
```

**Flow Description**:
1. **Real-time Data**: WebSocket subscribers connect to Coinbase streams
2. **Historical Data**: REST API fetches OHLCV candles on schedule
3. **Storage**: Raw ticks and processed candles stored in PostgreSQL
4. **Processing**: Data normalized and stored in unified schema
5. **Aggregation**: Real-time candle aggregator maintains live OHLCV data

### 2. Sentiment Analysis Pipeline

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│  News Sources   │───▶│  Collection     │───▶│  Scoring        │
│  • CryptoPanic  │    │  • RSS feeds    │    │  • Lexicon      │
│  • CoinDesk     │    │  • API calls    │    │  • Confidence   │
│  • CoinTelegraph│    │  • Deduplication│    │  • Normalization│
└─────────────────┘    └─────────────────┘    └─────────────────┘
                                                      │
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│  Signal Filter  │◀───│  Aggregation    │◀───│  Storage        │
│  • Z-score gate │    │  • Time windows │    │  • Events       │
│  • Thresholds   │    │  • Statistics   │    │  • Aggregates   │
│  • Strategy use │    │  • Rolling avg  │    │  • Metadata     │
└─────────────────┘    └─────────────────┘    └─────────────────┘
```

**Flow Description**:
1. **Collection**: FetchCryptopanicJob and FetchNewsJob retrieve articles
2. **Scoring**: ScoreSentimentJob applies lexicon-based sentiment scoring
3. **Aggregation**: AggregateSentimentJob creates rolling time-window summaries
4. **Z-Score Calculation**: Statistical normalization for signal generation
5. **Signal Filtering**: Sentiment gates applied to trading signals

### 3. Trading Signal Generation

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│  Market Data    │───▶│  Multi-timeframe│───▶│  Signal         │
│  • 1h candles   │    │  Analysis       │    │  Generation     │
│  • 15m candles  │    │  • Trend (1h)   │    │  • Entry price  │
│  • 5m candles   │    │  • Confirm (15m)│    │  • Stop loss    │
│  • 1m candles   │    │  • Entry (5m)   │    │  • Take profit  │
└─────────────────┘    │  • Timing (1m)  │    │  • Quantity     │
                       └─────────────────┘    └─────────────────┘
                                │                      │
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│  Execution      │◀───│  Risk           │◀───│  Sentiment      │
│  • Order place  │    │  Management     │    │  Filter         │
│  • Position mgmt│    │  • Position size│    │  • Z-score gate │
│  • Monitoring   │    │  • Risk limits  │    │  • Confidence   │
└─────────────────┘    │  • Validation   │    │  • Threshold    │
                       └─────────────────┘    └─────────────────┘
```

**Flow Description**:
1. **Multi-Timeframe Analysis**: 1h trend, 15m confirmation, 5m entry triggers, 1m timing
2. **Sentiment Gating**: Signals filtered by sentiment z-score thresholds
3. **Risk Management**: Position sizing based on volatility and equity
4. **Contract Resolution**: Automatic rollover to current month contracts
5. **Execution**: Order placement through FuturesExecutor with risk controls

### 4. Day Trading Position Management

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│  Signal Entry   │───▶│  Position       │───▶│  Risk           │
│  • 1m precision │    │  Tracking       │    │  Monitoring     │
│  • 5m confirm   │    │  • Entry time   │    │  • Stop loss    │
│  • Rapid entry  │    │  • Target P&L   │    │  • Take profit  │
└─────────────────┘    │  • Duration     │    │  • Time limits  │
                       └─────────────────┘    └─────────────────┘
                                │                      │
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│  End-of-Day     │◀───│  Intraday       │◀───│  Performance    │
│  Closure        │    │  Management     │    │  Tracking       │
│  • Force close  │    │  • Adjustments  │    │  • P&L calc     │
│  • P&L settle   │    │  • Scaling      │    │  • Statistics   │
│  • Cleanup      │    │  • Monitoring   │    │  • Reporting    │
└─────────────────┘    └─────────────────┘    └─────────────────┘
```

**Flow Description**:
1. **Signal Processing**: GenerateSignalsJob and RapidSignalEvaluationJob produce trading signals
2. **Risk Validation**: FuturesExecutor applies risk controls and position sizing
3. **Order Placement**: Integration with Coinbase Advanced Trade API
4. **Position Monitoring**: Continuous tracking and adjustment throughout the day
5. **End-of-Day Closure**: Automatic position closure for day trading compliance

## Component Interactions

### Market Data Flow
```
Coinbase WebSocket → Subscriber Services → Real-time Aggregator → Database Models → Strategy Services
```

### Trading Flow
```
Strategy Services → Signal Generation → Risk Management → Order Execution → Position Tracking
```

### Sentiment Flow
```
News APIs → Sentiment Events → Scoring → Aggregation → Signal Filtering
```

### Background Processing Flow
```
Cron Schedules → GoodJob Queue → Background Jobs → Service Layer → Database Updates
```

## Key Design Principles

### 1. Event-Driven Architecture
- **WebSocket Integration**: Real-time market data processing
- **Job-based Processing**: Asynchronous background operations
- **Signal Broadcasting**: Real-time signal distribution via WebSocket

### 2. Modular Service Design
- **Single Responsibility**: Each service handles one specific domain
- **Dependency Injection**: Services accept logger and configuration
- **Error Handling**: Comprehensive error tracking with Sentry

### 3. Time-Series Data Optimization
- **Efficient Storage**: Optimized database schema for OHLCV data
- **Fast Queries**: Indexed queries for time-series analysis
- **Real-time Updates**: Live candle aggregation from tick data

### 4. Risk Management First
- **Position Limits**: Configurable position sizing and limits
- **Stop Losses**: Automatic risk controls on all positions
- **Day Trading Compliance**: Automatic end-of-day position closure

### 5. Observability & Monitoring
- **Health Checks**: Comprehensive system health monitoring
- **Error Tracking**: Sentry integration for error monitoring
- **Performance Monitoring**: Database query and API call tracking
- **Slack Integration**: Real-time notifications and bot control

## Scalability Considerations

### Horizontal Scaling
- **Stateless Services**: All services are stateless and scalable
- **Job Workers**: GoodJob supports multiple worker processes
- **Database Connection Pooling**: Optimized database connections

### Performance Optimization
- **Database Indexing**: Optimized indexes for time-series queries
- **Connection Reuse**: Persistent WebSocket and HTTP connections
- **Caching**: Strategic caching of frequently accessed data

### Reliability Features
- **Job Retry Logic**: Automatic retry for failed background jobs
- **Circuit Breakers**: API failure protection
- **Graceful Degradation**: System continues operating with reduced functionality

## AI Chat Interface Architecture

### Chat Interface Data Flow

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│  User Input     │───▶│  ChatBotService │───▶│  AI Processing  │
│  • Natural lang │    │  • Sanitization │    │  • OpenRouter   │
│  • Commands     │    │  • Session mgmt │    │  • ChatGPT      │
│  • CLI/Terminal │    │  • Audit log    │    │  • Fallback     │
└─────────────────┘    └─────────────────┘    └─────────────────┘
                                │                      │
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│  Response       │◀───│  Command        │◀───│  Context        │
│  • Formatted    │    │  Execution      │    │  Building       │
│  • Typed output │    │  • Trading ops  │    │  • Session hist │
│  • Error handle │    │  • Queries      │    │  • Market data  │
└─────────────────┘    │  • System ctrl  │    │  • Trade status │
                       └─────────────────┘    └─────────────────┘
                                │
                       ┌─────────────────┐
                       │  Memory &       │
                       │  Audit          │
                       │  • ChatSession  │
                       │  • ChatMessage  │
                       │  • Audit logs   │
                       └─────────────────┘
```

### Chat Interface Components

1. **Input Processing**: Natural language sanitization and validation
2. **AI Interpretation**: Dual-provider AI with automatic fallback (OpenRouter → ChatGPT → Pattern Matching)
3. **Command Routing**: Intelligent routing to trading services based on intent
4. **Context Management**: Profit-focused conversation history with 4K token optimization
5. **Security Logging**: Comprehensive audit trail for compliance and security
6. **Response Formatting**: User-friendly output with structured data and error handling

### Performance Characteristics

- **AI Response Time**: ~1-2 seconds average
- **Local Fallback**: <100ms for pattern matching
- **Session Memory**: Automatic pruning at 200 messages  
- **Context Optimization**: Smart token management for AI APIs
- **Concurrent Sessions**: Support for multiple simultaneous users

---

**Next**: [Database Schema](Database-Schema) | **Up**: [Home](Home)