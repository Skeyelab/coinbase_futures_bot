# Services Documentation

## Overview

The services layer contains the core business logic of the coinbase_futures_bot. Services are organized into logical modules that handle specific aspects of the trading system.

## Service Architecture

```
app/services/
├── coinbase/                 # Coinbase API client services
│   ├── client.rb            # Unified client interface
│   ├── advanced_trade_client.rb  # Futures trading API
│   └── exchange_client.rb   # Spot market data API
├── execution/               # Trading execution services
│   └── futures_executor.rb # Order execution and risk management
├── market_data/            # Market data ingestion services
│   ├── coinbase_rest.rb    # REST API client for historical data
│   ├── coinbase_futures_subscriber.rb  # Futures WebSocket client
│   ├── coinbase_spot_subscriber.rb     # Spot WebSocket client
│   ├── coinbase_derivatives_subscriber.rb  # Derivatives data
│   └── futures_contract_manager.rb     # Contract lifecycle management
├── paper_trading/          # Simulation services
│   └── exchange_simulator.rb  # Paper trading simulation
├── sentiment/              # Sentiment analysis services
│   ├── crypto_panic_client.rb    # News data source
│   └── simple_lexicon_scorer.rb  # Sentiment scoring
├── strategy/               # Trading strategy services
│   ├── multi_timeframe_signal.rb  # Main trading strategy
│   ├── spot_driven_strategy.rb    # Spot-based signals
│   └── pullback_1h.rb            # Pullback strategy
├── trading/                # Position management services
│   └── coinbase_positions.rb     # Position tracking
├── backtest/               # Backtesting services
│   └── spot_db_replay.rb   # Historical data replay
└── cost_model.rb           # Trading cost calculations
```

## Service Categories

### 1. Market Data Services
- **Purpose**: Ingest and normalize market data from various sources
- **Key Services**: CoinbaseRest, CoinbaseFuturesSubscriber, FuturesContractManager
- **Documentation**: [market-data.md](market-data.md)

### 2. Trading Services
- **Purpose**: Handle order execution, position management, and risk controls
- **Key Services**: FuturesExecutor, CoinbasePositions, DayTradingPositionManager
- **Documentation**: [trading.md](trading.md)

### 3. Strategy Services
- **Purpose**: Generate trading signals and manage strategy logic
- **Key Services**: MultiTimeframeSignal, SpotDrivenStrategy
- **Documentation**: [strategies.md](strategies.md)

### 4. External API Clients
- **Purpose**: Interface with external APIs (Coinbase, CryptoPanic)
- **Key Services**: AdvancedTradeClient, ExchangeClient, CryptoPanicClient
- **Documentation**: [api-clients.md](api-clients.md)

### 5. Sentiment Analysis Services
- **Purpose**: Process news data and generate sentiment signals
- **Key Services**: CryptoPanicClient, SimpleLexiconScorer
- **Documentation**: [sentiment.md](sentiment.md)

## Service Design Patterns

### 1. Initialization Pattern
All services follow a consistent initialization pattern:

```ruby
class ServiceName
  def initialize(logger: Rails.logger, **options)
    @logger = logger
    # Additional initialization
  end
end
```

### 2. Error Handling
Services implement consistent error handling:

```ruby
def api_call
  begin
    # API operation
  rescue StandardError => e
    @logger.error("Operation failed: #{e.message}")
    handle_error(e)
  end
end
```

### 3. Configuration
Services use environment variables and configuration objects:

```ruby
def initialize(config = {})
  @config = DEFAULTS.merge(config)
  @api_key = ENV.fetch('API_KEY')
end
```

### 4. Dependency Injection
Services accept dependencies for testability:

```ruby
def initialize(http_client: Faraday.new, logger: Rails.logger)
  @http_client = http_client
  @logger = logger
end
```

## Common Interfaces

### Authentication Services
Services requiring authentication implement:
- `test_auth` - Validate API credentials
- `authenticated?` - Check authentication status

### Market Data Services
Market data services implement:
- `subscribe(product_ids)` - Subscribe to data feeds
- `start` - Begin data collection
- `stop` - Stop data collection

### Trading Services
Trading services implement:
- `place_order(params)` - Execute trades
- `list_positions` - Get current positions
- `cancel_order(order_id)` - Cancel pending orders

## Error Handling Strategy

### Retry Logic
Services implement exponential backoff for transient failures:

```ruby
def with_retry(max_attempts: 3)
  attempts = 0
  begin
    yield
  rescue RetryableError => e
    attempts += 1
    if attempts < max_attempts
      sleep(2 ** attempts)
      retry
    else
      raise
    end
  end
end
```

### Circuit Breaker
For external service protection:

```ruby
def call_external_service
  if circuit_breaker.open?
    raise CircuitBreakerOpen
  end

  # Make API call
rescue APIError => e
  circuit_breaker.record_failure
  raise
end
```

## Testing Strategy

### Unit Testing
Each service should have comprehensive unit tests:

```ruby
RSpec.describe SomeService do
  let(:service) { described_class.new(logger: nil) }

  describe '#method_name' do
    it 'performs expected operation' do
      # Test implementation
    end
  end
end
```

### Integration Testing
Critical integration points should be tested:

```ruby
RSpec.describe 'Market Data Integration' do
  it 'processes real market data' do
    VCR.use_cassette('market_data') do
      # Integration test
    end
  end
end
```

### Mocking External Services
Use VCR for HTTP interactions:

```ruby
VCR.use_cassette('coinbase_api') do
  service.fetch_data
end
```

## Performance Considerations

### Connection Pooling
Services reuse connections where possible:

```ruby
def http_client
  @http_client ||= Faraday.new do |f|
    f.adapter :net_http_persistent
  end
end
```

### Caching
Appropriate caching for expensive operations:

```ruby
def expensive_calculation
  Rails.cache.fetch("calc_#{key}", expires_in: 1.hour) do
    perform_calculation
  end
end
```

### Resource Management
Proper cleanup of resources:

```ruby
def cleanup
  @websocket&.close
  @http_client&.close
end
```

## Monitoring and Observability

### Logging
Services log important events:

```ruby
@logger.info("Operation started", operation: 'fetch_data', symbol: symbol)
@logger.error("Operation failed", error: e.message, backtrace: e.backtrace)
```

### Metrics
Consider adding metrics collection:

```ruby
def track_operation(&block)
  start_time = Time.current
  result = yield
  duration = Time.current - start_time
  StatsD.histogram('operation.duration', duration)
  result
end
```

## Service Documentation Index

- [Market Data Services](market-data.md)
- [Trading Services](trading.md)
- [Strategy Services](strategies.md)
- [API Clients](api-clients.md)
- [Sentiment Analysis](sentiment.md)
