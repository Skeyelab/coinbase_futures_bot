# Market Data Services

## Overview

Market data services handle the ingestion, processing, and storage of financial market data from various sources. These services form the foundation of the trading system by providing real-time and historical price information.

## Service Architecture

```
Market Data Flow:
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│  Coinbase APIs │───▶│  Data Services  │───▶│   Database      │
│  • Spot WS      │    │  • Subscribers  │    │  • Candles      │
│  • Futures WS   │    │  • REST Client  │    │  • Ticks        │
│  • REST API     │    │  • Normalizers  │    │  • TradingPairs │
└─────────────────┘    └─────────────────┘    └─────────────────┘
```

## Core Services

### CoinbaseRest

**Location**: `app/services/market_data/coinbase_rest.rb`

**Purpose**: Handles REST API interactions for historical data and product information.

**Key Methods**:
- `upsert_products` - Sync trading pair metadata
- `upsert_1m_candles(product_id, start_time, end_time)` - Fetch 1-minute candles
- `upsert_5m_candles(product_id, start_time, end_time)` - Fetch 5-minute candles
- `upsert_15m_candles(product_id, start_time, end_time)` - Fetch 15-minute candles
- `upsert_1h_candles(product_id, start_time, end_time)` - Fetch 1-hour candles
- `upsert_1m_candles_chunked(product_id, start_time, end_time, chunk_days)` - Chunked fetching

**Configuration**:
```ruby
# Environment variables
COINBASE_CANDLES_URL # Override candles endpoint
COINBASE_PRODUCTS_URL # Override products endpoint
```

**Example Usage**:
```ruby
rest = MarketData::CoinbaseRest.new
rest.upsert_products

# Fetch recent 1-hour candles for BTC
rest.upsert_1h_candles(
  product_id: "BTC-USD",
  start_time: 24.hours.ago,
  end_time: Time.current
)
```

**Error Handling**:
- Automatic retry with exponential backoff
- Rate limiting protection
- Data validation and deduplication

### CoinbaseFuturesSubscriber

**Location**: `app/services/market_data/coinbase_futures_subscriber.rb`

**Purpose**: WebSocket client for real-time futures market data.

**Key Methods**:
- `initialize(product_ids:, logger: Rails.logger)` - Setup subscription
- `start` - Begin WebSocket connection and data streaming
- `stop` - Close connection and cleanup

**Configuration**:
```ruby
# Environment variables
COINBASE_FUTURES_WS_URL # WebSocket endpoint URL
```

**Message Handling**:
```ruby
def handle_message(data)
  case data['type']
  when 'ticker'
    process_ticker(data)
  when 'heartbeat'
    update_heartbeat
  else
    @logger.warn("Unknown message type: #{data['type']}")
  end
end
```

**Example Usage**:
```ruby
subscriber = MarketData::CoinbaseFuturesSubscriber.new(
  product_ids: ["BTC-USD-PERP", "ETH-USD-PERP"]
)
subscriber.start # Blocks until stopped
```

### CoinbaseSpotSubscriber

**Location**: `app/services/market_data/coinbase_spot_subscriber.rb`

**Purpose**: WebSocket client for real-time spot market data.

**Key Methods**:
- `initialize(product_ids:, logger: Rails.logger)` - Setup subscription
- `start` - Begin WebSocket connection
- `handle_ticker(data)` - Process ticker messages

**Message Types**:
- `ticker` - Real-time price updates
- `heartbeat` - Connection health checks
- `error` - Error notifications

**Data Storage**:
```ruby
def store_tick(product_id, price, time)
  Tick.create!(
    product_id: product_id,
    price: price,
    observed_at: time
  )
end
```

### CoinbaseDerivativesSubscriber

**Location**: `app/services/market_data/coinbase_derivatives_subscriber.rb`

**Purpose**: Specialized subscriber for derivatives market data.

**Features**:
- Handles futures-specific data formats
- Contract lifecycle management
- Basis calculation and tracking

### FuturesContractManager

**Location**: `app/services/market_data/futures_contract_manager.rb`

**Purpose**: Manages futures contract lifecycles, including rollover and expiration handling.

**Key Methods**:
- `current_month_contract(base_currency)` - Get current month contract
- `upcoming_month_contract(base_currency)` - Get next month contract
- `rollover_needed?(days_before_expiry: 3)` - Check if rollover required
- `expiring_contracts(days_ahead: 7)` - Find contracts nearing expiration
- `update_all_contracts` - Refresh contract metadata

**Contract Resolution Logic**:
```ruby
def resolve_contract(product_id)
  # Handle current month contract resolution
  if product_id.end_with?('-PERP')
    current_month_contract(extract_base_currency(product_id))
  else
    TradingPair.find_by(product_id: product_id)
  end
end
```

**Rollover Management**:
```ruby
def perform_rollover(base_currency)
  current = current_month_contract(base_currency)
  upcoming = upcoming_month_contract(base_currency)

  if current&.expiring_soon? && upcoming&.tradeable?
    # Execute rollover logic
    transfer_positions(current, upcoming)
  end
end
```

## Data Models Integration

### Candle Storage
```ruby
# Candle data normalization
def normalize_candle_data(raw_data, symbol, timeframe)
  {
    symbol: symbol,
    timeframe: timeframe,
    timestamp: Time.parse(raw_data[0]),
    low: BigDecimal(raw_data[1]),
    high: BigDecimal(raw_data[2]),
    open: BigDecimal(raw_data[3]),
    close: BigDecimal(raw_data[4]),
    volume: BigDecimal(raw_data[5])
  }
end
```

### Tick Storage
```ruby
# Real-time tick storage
def store_ticker_data(ticker_data)
  Tick.create!(
    product_id: ticker_data['product_id'],
    price: BigDecimal(ticker_data['price']),
    observed_at: Time.parse(ticker_data['time'])
  )
end
```

### Trading Pair Management
```ruby
# Product metadata synchronization
def sync_product_metadata(products)
  products.each do |product|
    TradingPair.upsert(
      {
        product_id: product['id'],
        base_currency: product['base_currency'],
        quote_currency: product['quote_currency'],
        status: product['status'],
        # ... other fields
      },
      unique_by: :product_id
    )
  end
end
```

## Performance Optimization

### Chunked Data Fetching
For large historical data requests:

```ruby
def upsert_1m_candles_chunked(product_id:, start_time:, end_time:, chunk_days: 1)
  current_start = start_time

  while current_start < end_time
    chunk_end = [current_start + chunk_days.days, end_time].min

    upsert_1m_candles(
      product_id: product_id,
      start_time: current_start,
      end_time: chunk_end
    )

    current_start = chunk_end
    sleep(0.1) # Rate limiting
  end
end
```

### Connection Management
```ruby
def websocket_client
  @websocket_client ||= WebSocket::Client::Simple.connect(ws_url) do |ws|
    ws.on(:message) { |msg| handle_message(JSON.parse(msg.data)) }
    ws.on(:error) { |error| handle_error(error) }
    ws.on(:close) { |code| handle_close(code) }
  end
end
```

### Data Deduplication
```ruby
def upsert_candles(candles_data, symbol, timeframe)
  candles_data.each do |candle_data|
    Candle.upsert(
      normalize_candle_data(candle_data, symbol, timeframe),
      unique_by: [:symbol, :timeframe, :timestamp]
    )
  end
end
```

## Error Handling

### WebSocket Reconnection
```ruby
def start_with_reconnect
  loop do
    begin
      start_websocket
    rescue WebSocket::Error => e
      @logger.error("WebSocket error: #{e.message}")
      sleep(5)
      retry
    end
  end
end
```

### API Rate Limiting
```ruby
def handle_rate_limit(response)
  if response.status == 429
    retry_after = response.headers['Retry-After']&.to_i || 60
    @logger.warn("Rate limited, waiting #{retry_after} seconds")
    sleep(retry_after)
    return true
  end
  false
end
```

### Data Validation
```ruby
def validate_candle_data(data)
  required_fields = %w[timestamp open high low close volume]
  missing_fields = required_fields - data.keys

  if missing_fields.any?
    raise DataValidationError, "Missing fields: #{missing_fields.join(', ')}"
  end

  if data['high'] < data['low']
    raise DataValidationError, "High price cannot be less than low price"
  end
end
```

## Monitoring and Alerting

### Health Checks
```ruby
def health_check
  {
    websocket_connected: @websocket&.connected?,
    last_message_at: @last_message_at,
    message_count: @message_count,
    error_count: @error_count
  }
end
```

### Metrics Collection
```ruby
def track_message_metrics(message_type)
  @message_count += 1
  @last_message_at = Time.current

  # Send to metrics collector
  StatsD.increment("market_data.#{message_type}.count")
  StatsD.gauge("market_data.lag", Time.current - @last_message_at)
end
```

## Configuration

### Environment Variables
```bash
# WebSocket URLs
COINBASE_FUTURES_WS_URL=wss://advanced-trade-ws.coinbase.com
COINBASE_SPOT_WS_URL=wss://ws-feed.exchange.coinbase.com

# REST API URLs
COINBASE_CANDLES_URL=https://api.exchange.coinbase.com/products/%s/candles
COINBASE_PRODUCTS_URL=https://api.exchange.coinbase.com/products

# Data collection settings
CANDLES_BACKFILL_DAYS=7
TICK_RETENTION_DAYS=30
```

### Service Configuration
```ruby
# config/initializers/market_data.rb
MarketData.configure do |config|
  config.default_timeframes = %w[1m 5m 15m 1h]
  config.max_candles_per_request = 300
  config.websocket_timeout = 30.seconds
  config.retry_attempts = 3
end
```

## Testing

### Unit Tests
```ruby
RSpec.describe MarketData::CoinbaseRest do
  let(:service) { described_class.new }

  describe '#upsert_1h_candles' do
    it 'fetches and stores candle data' do
      VCR.use_cassette('candles_btc_1h') do
        service.upsert_1h_candles(
          product_id: 'BTC-USD',
          start_time: 1.day.ago,
          end_time: Time.current
        )
      end

      expect(Candle.count).to be > 0
    end
  end
end
```

### Integration Tests
```ruby
RSpec.describe 'Market Data Integration' do
  it 'processes live websocket data' do
    subscriber = MarketData::CoinbaseFuturesSubscriber.new(
      product_ids: ['BTC-USD-PERP']
    )

    # Test with recorded WebSocket data
    expect { subscriber.start }.to change { Tick.count }
  end
end
```

## Troubleshooting

### Common Issues
1. **WebSocket Connection Drops**: Check network connectivity and firewall settings
2. **Rate Limiting**: Implement exponential backoff and respect API limits
3. **Data Gaps**: Verify time synchronization and handle clock drift
4. **Memory Usage**: Monitor for memory leaks in long-running connections

### Debug Commands
```bash
# Check recent tick data
bin/rails console -e production
Tick.where(product_id: 'BTC-USD-PERP').order(:observed_at).last(10)

# Verify candle data integrity
Candle.where(symbol: 'BTC-USD', timeframe: '1h').where('high < low').count

# Monitor WebSocket health
curl http://localhost:3000/health/market_data
```
