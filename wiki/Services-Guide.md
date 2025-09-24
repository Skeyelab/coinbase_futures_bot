# Services Guide

## Overview

The services layer contains the core business logic of the coinbase_futures_bot. This comprehensive guide documents all **41 services** organized into logical modules that handle specific aspects of the trading system.

## Service Architecture

```
app/services/
├── coinbase/                 # Coinbase API client services (3 services)
├── execution/               # Trading execution services (1 service)
├── market_data/            # Market data ingestion services (6 services)
├── paper_trading/          # Simulation services (1 service)
├── sentiment/              # Sentiment analysis services (6 services)
├── strategy/               # Trading strategy services (3 services)
├── trading/                # Position management services (3 services)
├── backtest/               # Backtesting services (1 service)
├── chat/                   # AI-powered chat interface services (3 services)
├── concerns/               # Shared service concerns (1 service)
└── standalone/             # Standalone utility services (13 services)
```

## Service Categories

### 1. Coinbase API Services (3 services)

#### Coinbase::Client
**Location**: `app/services/coinbase/client.rb`

**Purpose**: Unified client interface for Coinbase API interactions with automatic authentication and error handling.

**Key Features**:
- JWT-based authentication for Advanced Trade API
- Automatic token generation and renewal
- Request signing with private key
- Error handling and retry logic

**Usage**:
```ruby
client = Coinbase::Client.new
products = client.get_products
account = client.get_account(account_id)
```

#### Coinbase::AdvancedTradeClient
**Location**: `app/services/coinbase/advanced_trade_client.rb`

**Purpose**: Specialized client for Coinbase Advanced Trade API (futures trading).

**Key Methods**:
- `get_accounts` - Retrieve trading accounts
- `get_products` - Fetch available products
- `create_order(params)` - Place trading orders
- `get_fills(params)` - Retrieve order fills
- `get_orders(params)` - Get order history

**Usage**:
```ruby
client = Coinbase::AdvancedTradeClient.new
order = client.create_order({
  product_id: "BTC-USD",
  side: "buy",
  order_configuration: { limit_limit_gtc: { base_size: "0.1", limit_price: "45000" } }
})
```

#### Coinbase::ExchangeClient
**Location**: `app/services/coinbase/exchange_client.rb`

**Purpose**: Client for Coinbase Exchange API (spot market data).

**Key Methods**:
- `get_products` - Retrieve spot products
- `get_product_candles(product_id, params)` - Fetch OHLCV data
- `get_product_ticker(product_id)` - Get current price ticker

**Usage**:
```ruby
client = Coinbase::ExchangeClient.new
candles = client.get_product_candles("BTC-USD", {
  start: 1.hour.ago.iso8601,
  end: Time.current.iso8601,
  granularity: 300
})
```

### 2. Market Data Services (6 services)

#### MarketData::CoinbaseRest
**Location**: `app/services/market_data/coinbase_rest.rb`

**Purpose**: REST API client for historical market data collection and product synchronization.

**Key Methods**:
- `upsert_products` - Sync trading pair metadata
- `upsert_1m_candles(product_id, start_time, end_time)` - Fetch 1-minute candles
- `upsert_5m_candles(product_id, start_time, end_time)` - Fetch 5-minute candles
- `upsert_15m_candles(product_id, start_time, end_time)` - Fetch 15-minute candles
- `upsert_1h_candles(product_id, start_time, end_time)` - Fetch 1-hour candles

**Usage**:
```ruby
rest = MarketData::CoinbaseRest.new
rest.upsert_products
rest.upsert_1h_candles("BTC-USD", 1.day.ago, Time.current)
```

#### MarketData::CoinbaseSpotSubscriber
**Location**: `app/services/market_data/coinbase_spot_subscriber.rb`

**Purpose**: WebSocket client for real-time spot market data streaming.

**Key Features**:
- Real-time ticker data via WebSocket
- Automatic reconnection and error handling
- Tick data processing and callbacks
- Connection health monitoring

**Usage**:
```ruby
subscriber = MarketData::CoinbaseSpotSubscriber.new(
  product_ids: ["BTC-USD"],
  on_ticker: ->(tick) { puts "Price: #{tick['price']}" }
)
subscriber.start
```

#### MarketData::CoinbaseFuturesSubscriber
**Location**: `app/services/market_data/coinbase_futures_subscriber.rb`

**Purpose**: WebSocket client for real-time futures market data streaming.

**Key Features**:
- Futures ticker data via Advanced Trade WebSocket
- Real-time candle aggregation
- Multiple product subscription
- Error tracking with Sentry

**Usage**:
```ruby
subscriber = MarketData::CoinbaseFuturesSubscriber.new(
  product_ids: ["BTC-USD"],
  on_ticker: ->(tick) { process_futures_tick(tick) }
)
subscriber.start
```

#### MarketData::RealTimeCandleAggregator
**Location**: `app/services/market_data/real_time_candle_aggregator.rb`

**Purpose**: Real-time OHLCV candle aggregation from tick data streams.

**Key Features**:
- Multi-timeframe candle maintenance (1m, 5m, 15m, 1h)
- Tick buffering and processing
- Real-time candle updates
- Memory-efficient tick processing

**Usage**:
```ruby
aggregator = MarketData::RealTimeCandleAggregator.new
aggregator.process_tick({
  "product_id" => "BTC-USD",
  "price" => "45000.00",
  "time" => Time.current.iso8601
})
```

#### MarketData::FuturesContractManager
**Location**: `app/services/market_data/futures_contract_manager.rb`

**Purpose**: Futures contract lifecycle management and rollover logic.

**Key Features**:
- Current month contract resolution
- Contract expiration monitoring
- Automatic rollover logic
- Contract metadata management

**Usage**:
```ruby
manager = MarketData::FuturesContractManager.new
current_contract = manager.current_month_contract("BTC")
next_contract = manager.next_month_contract("BTC")
```

#### MarketData::CoinbaseDerivativesSubscriber
**Location**: `app/services/market_data/coinbase_derivatives_subscriber.rb`

**Purpose**: Specialized WebSocket client for derivatives market data.

**Key Features**:
- Derivatives-specific data streams
- Futures and options data handling
- Advanced market data processing

### 3. Trading Strategy Services (3 services)

#### Strategy::MultiTimeframeSignal
**Location**: `app/services/strategy/multi_timeframe_signal.rb`

**Purpose**: Main trading strategy implementing multi-timeframe analysis for day trading.

**Key Features**:
- **Multi-timeframe Analysis**: 1h trend, 15m confirmation, 5m entry, 1m timing
- **EMA-based Signals**: Configurable EMA periods for different timeframes
- **Risk Management**: Position sizing based on volatility and equity
- **Sentiment Integration**: Sentiment z-score filtering
- **Day Trading Optimization**: Tight stops and quick profits

**Configuration**:
```ruby
strategy = Strategy::MultiTimeframeSignal.new(
  ema_1h_short: 21,    # 1h short EMA
  ema_1h_long: 50,     # 1h long EMA
  ema_15m: 21,         # 15m EMA
  ema_5m: 13,          # 5m EMA
  ema_1m: 8,           # 1m EMA
  tp_target: 0.004,    # 40 bps take profit
  sl_target: 0.003     # 30 bps stop loss
)
```

**Usage**:
```ruby
signal = strategy.signal(symbol: "BTC-USD", equity_usd: 50000)
if signal
  puts "#{signal[:side]} #{signal[:quantity]} at $#{signal[:price]}"
  puts "TP: $#{signal[:tp]}, SL: $#{signal[:sl]}"
end
```

#### Strategy::SpotDrivenStrategy
**Location**: `app/services/strategy/spot_driven_strategy.rb`

**Purpose**: Strategy that generates futures signals based on spot market analysis.

**Key Features**:
- Spot market trend analysis
- Sentiment-based signal filtering
- Multi-product signal generation
- Z-score threshold gating

**Usage**:
```ruby
strategy = Strategy::SpotDrivenStrategy.new
signals = strategy.generate_signals(
  product_ids: ["BTC-USD", "ETH-USD"],
  as_of: Time.current
)
```

#### Strategy::Pullback1h
**Location**: `app/services/strategy/pullback_1h.rb`

**Purpose**: Pullback entry strategy for trend-following trades.

**Key Features**:
- 1-hour timeframe pullback detection
- EMA-based trend confirmation
- Entry timing optimization

### 4. Execution Services (1 service)

#### Execution::FuturesExecutor
**Location**: `app/services/execution/futures_executor.rb`

**Purpose**: Order execution engine with comprehensive risk management for futures trading.

**Key Features**:
- **Order Placement**: Integration with Coinbase Advanced Trade API
- **Risk Controls**: Position limits, stop losses, take profits
- **Position Management**: Entry, exit, and adjustment logic
- **Error Handling**: Comprehensive error tracking and recovery
- **Paper Trading**: Simulation mode for testing

**Usage**:
```ruby
executor = Execution::FuturesExecutor.new
result = executor.execute_signal({
  symbol: "BTC-USD",
  side: "long",
  price: 45000.0,
  quantity: 2,
  stop_loss: 44500.0,
  take_profit: 45800.0
})
```

### 5. Trading Services (3 services)

#### Trading::CoinbasePositions
**Location**: `app/services/trading/coinbase_positions.rb`

**Purpose**: Position tracking and management for Coinbase futures accounts.

**Key Features**:
- Real-time position monitoring
- P&L calculation and tracking
- Position reconciliation
- Account balance management

**Usage**:
```ruby
positions = Trading::CoinbasePositions.new
current_positions = positions.get_positions
total_pnl = positions.calculate_total_pnl
```

#### Trading::DayTradingPositionManager
**Location**: `app/services/trading/day_trading_position_manager.rb`

**Purpose**: Specialized position management for day trading operations.

**Key Features**:
- **Intraday Position Tracking**: Same-day entry and exit
- **Time-based Risk Controls**: Automatic position closure
- **Performance Monitoring**: Intraday P&L tracking
- **Compliance**: Day trading rule enforcement

**Usage**:
```ruby
manager = Trading::DayTradingPositionManager.new
manager.monitor_positions
manager.force_end_of_day_closure
```

#### Trading::SwingPositionManager
**Location**: `app/services/trading/swing_position_manager.rb`

**Purpose**: Position management for multi-day swing trading positions.

**Key Features**:
- **Multi-day Positions**: Overnight position management
- **Contract Rollover**: Automatic contract expiration handling
- **Risk Monitoring**: Overnight exposure limits
- **Margin Management**: Leverage and margin monitoring

### 6. Sentiment Analysis Services (6 services)

#### Sentiment::CryptoPanicClient
**Location**: `app/services/sentiment/crypto_panic_client.rb`

**Purpose**: Client for CryptoPanic news API integration.

**Key Features**:
- News article fetching from CryptoPanic
- Filtering and deduplication
- Rate limit management
- Error handling and retry logic

**Usage**:
```ruby
client = Sentiment::CryptoPanicClient.new
news = client.fetch_news(currencies: ["BTC", "ETH"], limit: 50)
```

#### Sentiment::SimpleLexiconScorer
**Location**: `app/services/sentiment/simple_lexicon_scorer.rb`

**Purpose**: Lexicon-based sentiment scoring for news articles.

**Key Features**:
- Sentiment word analysis
- Confidence scoring
- Text preprocessing
- Normalized sentiment scores

**Usage**:
```ruby
scorer = Sentiment::SimpleLexiconScorer.new
result = scorer.score("Bitcoin reaches new all-time high!")
puts "Score: #{result[:score]}, Confidence: #{result[:confidence]}"
```

#### Sentiment::MultiSourceAggregator
**Location**: `app/services/sentiment/multi_source_aggregator.rb`

**Purpose**: Aggregates sentiment data from multiple news sources.

**Key Features**:
- Multi-source news collection
- Source weighting and prioritization
- Duplicate detection and removal
- Unified sentiment scoring

#### Sentiment::BaseNewsClient
**Location**: `app/services/sentiment/base_news_client.rb`

**Purpose**: Base class for news API clients with common functionality.

**Key Features**:
- Shared HTTP client configuration
- Rate limiting and error handling
- Response parsing and normalization
- Retry logic with exponential backoff

#### Sentiment::CoindeskRssClient
**Location**: `app/services/sentiment/coindesk_rss_client.rb`

**Purpose**: RSS client for CoinDesk news feed.

**Key Features**:
- RSS feed parsing
- Article extraction and normalization
- Publication date handling

#### Sentiment::CointelegraphRssClient
**Location**: `app/services/sentiment/cointelegraph_rss_client.rb`

**Purpose**: RSS client for CoinTelegraph news feed.

**Key Features**:
- RSS feed parsing
- Crypto-specific news filtering
- Content extraction and processing

### 7. Paper Trading Services (1 service)

#### PaperTrading::ExchangeSimulator
**Location**: `app/services/paper_trading/exchange_simulator.rb`

**Purpose**: Comprehensive paper trading simulation engine.

**Key Features**:
- **Realistic Order Fills**: Market impact and slippage simulation
- **Fee Calculation**: Trading fees and costs
- **Position Tracking**: Simulated position management
- **Performance Metrics**: P&L and statistics tracking
- **Market Data Integration**: Real-time price feeds

**Usage**:
```ruby
simulator = PaperTrading::ExchangeSimulator.new
order_result = simulator.place_order({
  symbol: "BTC-USD",
  side: "buy",
  quantity: 1,
  price: 45000.0,
  order_type: "limit"
})
```

### 8. Backtesting Services (1 service)

#### Backtest::SpotDbReplay
**Location**: `app/services/backtest/spot_db_replay.rb`

**Purpose**: Historical data replay engine for strategy backtesting.

**Key Features**:
- Historical tick data replay
- Strategy performance simulation
- Time-series data processing
- Performance metrics calculation

### 9. Chat Interface Services (3 services)

#### ChatBotService
**Location**: `app/services/chat_bot_service.rb`

**Purpose**: Main orchestrator for AI-powered trading bot chat interface with comprehensive natural language command processing.

**Key Features**:
- **Natural Language Processing**: Advanced command interpretation using AI services
- **Trading Control Integration**: Start/stop trading, emergency stop, position sizing
- **Session Management**: Persistent conversation history with context retention
- **Comprehensive Audit Logging**: Security-compliant tracking of all operations
- **Multi-layered Error Handling**: AI service fallbacks with graceful degradation
- **Memory-Aware Context**: Profit-focused conversation scoring and relevance ranking

**Command Categories**:
- Position & PnL queries ("show my positions", "current profit/loss")
- Signal analysis ("active signals", "recent alerts")
- Market data ("BTC price", "ETH volume")
- Trading control ("start trading", "emergency stop", "position sizing")
- System status ("health check", "bot status")
- Session management ("history", "search", "sessions")

**Usage**:
```ruby
bot = ChatBotService.new("session-123")
response = bot.process("show my positions")
puts response  # Formatted position summary

# Trading control (security-sensitive)
bot.process("start trading")  # Activates trading operations
bot.process("emergency stop") # Immediate position closure
```

**Security Features**:
- Input sanitization and validation
- Session isolation and secure ID generation
- Comprehensive audit logging for compliance
- Trading control action verification

#### AiCommandProcessorService
**Location**: `app/services/ai_command_processor_service.rb`

**Purpose**: AI service integration layer providing dual-provider support with automatic fallback mechanisms.

**Key Features**:
- **Dual AI Provider Support**: OpenRouter (Claude 3.5 Sonnet) with ChatGPT (GPT-4) fallback
- **Automatic Failover**: Seamless switching between providers on service failure
- **Context-Aware Processing**: Conversation history and trading context integration
- **Intelligent Retry Logic**: Service-specific error handling and recovery
- **Token Management**: Efficient context window management for AI APIs
- **Performance Monitoring**: Response time tracking and service health checks

**Usage**:
```ruby
processor = AiCommandProcessorService.new
response = processor.process_command(
  "show my trading positions",
  context: {
    session_id: "abc123",
    trading_status: "active",
    recent_interactions: [...]
  }
)
puts response[:content]  # AI-interpreted command intent
puts response[:provider] # "openrouter" or "openai"
```

**Configuration**:
```bash
OPENROUTER_API_KEY=your_openrouter_key  # Primary AI service
OPENAI_API_KEY=your_openai_key          # Fallback AI service
```

#### ChatAuditLogger
**Location**: `app/services/chat_audit_logger.rb`

**Purpose**: Comprehensive audit logging service for security compliance and operational tracking.

**Key Features**:
- **Security-Sensitive Action Tracking**: Special logging for trading control commands
- **Comprehensive Command Logging**: Full context capture for all chat interactions
- **Error and Fallback Tracking**: AI service failure monitoring and recovery logging
- **Session-Based Audit Trails**: Complete conversation tracking with security metadata
- **Compliance Reporting**: Structured audit reports for regulatory requirements
- **External Security Integration**: Support for external monitoring systems

**Audit Categories**:
- **Standard Commands**: Position queries, market data, system status
- **Trading Control**: Start/stop operations, emergency stops, position sizing
- **Security Events**: Failed authentication, suspicious patterns, error recovery
- **AI Service Events**: Provider failures, fallback usage, response times

**Usage**:
```ruby
# Standard command logging
ChatAuditLogger.log_command(
  session_id: "session-123",
  user_input: "show my positions",
  command_type: "position_query",
  ai_response: ai_response,
  result: result,
  execution_time: 1250
)

# Security-sensitive trading control
ChatAuditLogger.log_trading_control(
  session_id: "session-123",
  action: "emergency_stop",
  user_input: "emergency stop",
  result: stop_result,
  user_context: context
)

# AI service error tracking
ChatAuditLogger.log_ai_service_error(
  session_id: "session-123",
  user_input: "start trading",
  error: service_error,
  fallback_used: true
)
```

**Security Features**:
- Input sanitization in audit logs
- Risk-level categorization (LOW/MEDIUM/HIGH/CRITICAL)
- Trading status change tracking
- External security system integration

#### ChatMemoryService
**Location**: `app/services/chat_memory_service.rb`

**Purpose**: Intelligent conversation memory management with profit-focused scoring and context optimization.

**Key Features**:
- **Database-Backed Persistence**: Permanent conversation storage with ChatSession/ChatMessage models
- **Profit-Focused Scoring**: Intelligent relevance ranking based on trading outcomes
- **Context Window Management**: Smart truncation for AI API token limits (4K tokens)
- **Cross-Session Continuity**: Context retention and conversation resumption
- **Automatic Memory Pruning**: Efficient storage management keeping top 100-200 messages
- **Search and Retrieval**: Full-text search across conversation history

**Memory Intelligence**:
- **High Impact**: Trading control, emergency stops, position changes
- **Medium Impact**: Signal analysis, market data queries, profitable conversations
- **Low Impact**: General queries, help requests, system information

**Usage**:
```ruby
memory = ChatMemoryService.new("session-123")

# Store user interaction
memory.store_user_input("show my positions")

# Store bot response with context
memory.store_bot_response(formatted_response, result)

# Get AI-optimized context
context = memory.context_for_ai(4000)  # 4K token limit

# Search conversation history
results = memory.search_history("emergency stop")

# Get session summary
summary = memory.session_summary
```

### 10. Support Services (10 services)

#### SlackNotificationService
**Location**: `app/services/slack_notification_service.rb`

**Purpose**: Slack integration for notifications and alerts.

**Key Features**:
- Trading signal notifications
- System status alerts
- Error notifications
- Bot command responses

**Usage**:
```ruby
SlackNotificationService.signal_generated({
  symbol: "BTC-USD",
  side: "long",
  price: 45000.0,
  confidence: 85
})
```

#### SlackCommandHandler
**Location**: `app/services/slack_command_handler.rb`

**Purpose**: Handles Slack slash commands for bot control.

**Available Commands**:
- `/bot-status` - Get current bot status
- `/bot-positions` - View active positions
- `/bot-pnl` - Check P&L performance
- `/bot-pause` - Pause trading operations
- `/bot-resume` - Resume trading operations
- `/bot-stop` - Emergency stop all operations

#### RealTimeSignalEvaluator
**Location**: `app/services/real_time_signal_evaluator.rb`

**Purpose**: Real-time signal evaluation and alert generation.

**Key Features**:
- Continuous market monitoring
- Multi-strategy evaluation
- Signal confidence scoring
- Rate limiting and deduplication

#### SignalBroadcaster
**Location**: `app/services/signal_broadcaster.rb`

**Purpose**: WebSocket broadcasting for real-time signal distribution.

**Key Features**:
- Real-time signal broadcasting
- Client connection management
- Message formatting and delivery

#### CostModel
**Location**: `app/services/cost_model.rb`

**Purpose**: Trading cost calculation and analysis.

**Key Features**:
- Fee calculation (maker/taker fees)
- Slippage estimation
- Break-even analysis
- Cost optimization recommendations

#### ContractExpiryManager
**Location**: `app/services/contract_expiry_manager.rb`

**Purpose**: Futures contract expiration and rollover management.

**Key Features**:
- Expiration date tracking
- Rollover notifications
- Contract transition management

#### FuturesContract
**Location**: `app/services/futures_contract.rb`

**Purpose**: Futures contract metadata and utilities.

**Key Features**:
- Contract specification parsing
- Expiration date calculations
- Contract naming conventions

#### SentryHelper
**Location**: `app/services/sentry_helper.rb`

**Purpose**: Centralized Sentry error tracking and monitoring utilities.

#### SentryMonitoringService
**Location**: `app/services/sentry_monitoring_service.rb`

**Purpose**: Advanced Sentry monitoring and alerting.

#### SentryPerformanceService
**Location**: `app/services/sentry_performance_service.rb`

**Purpose**: Performance monitoring and optimization tracking.

#### ChatMemoryService
**Location**: `app/services/chat_memory_service.rb`

**Purpose**: Session memory management for chat bot interactions.

**Key Features**:
- Conversation history tracking
- Session state management
- Memory cleanup and optimization

## Service Usage Patterns

### 1. Error Handling
All services implement comprehensive error handling with Sentry integration:

```ruby
class MyService
  include SentryServiceTracking

  def process_data
    track_service_call("process_data") do
      # Service logic here
    end
  rescue => e
    # Automatic Sentry tracking via concern
    raise
  end
end
```

### 2. Configuration
Services use environment variables for configuration:

```ruby
class ApiClient
  def initialize
    @api_key = ENV.fetch("API_KEY")
    @timeout = ENV.fetch("API_TIMEOUT", 30).to_i
    @base_url = ENV.fetch("API_BASE_URL", "https://api.example.com")
  end
end
```

### 3. Logging
Structured logging with contextual information:

```ruby
def process_order(order)
  @logger.info("[OrderProcessor] Processing order", {
    order_id: order.id,
    symbol: order.symbol,
    side: order.side
  })
end
```

### 4. Dependency Injection
Services accept dependencies for testability:

```ruby
def initialize(logger: Rails.logger, http_client: Faraday.new)
  @logger = logger
  @http_client = http_client
end
```

## Testing Services

Services are thoroughly tested with RSpec:

```ruby
# spec/services/strategy/multi_timeframe_signal_spec.rb
RSpec.describe Strategy::MultiTimeframeSignal do
  let(:strategy) { described_class.new }
  
  describe "#signal" do
    context "with sufficient candle data" do
      it "generates valid trading signals" do
        signal = strategy.signal(symbol: "BTC-USD", equity_usd: 10000)
        expect(signal).to include(:side, :price, :quantity)
      end
    end
  end
end
```

## Service Performance

### Monitoring
- Sentry performance tracking
- Database query monitoring
- API call latency tracking
- Memory usage optimization

### Optimization
- Connection pooling for API clients
- Caching for frequently accessed data
- Batch processing for bulk operations
- Efficient database queries

---

**Next**: [Background Jobs](Background-Jobs) | **Up**: [Home](Home)