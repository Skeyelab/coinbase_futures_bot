# Trading Services Documentation

## Overview

The trading services handle position management, order execution, and risk controls for the coinbase_futures_bot. These services ensure proper position lifecycle management and regulatory compliance for day trading operations.

## Service Architecture

```
app/services/trading/
├── coinbase_positions.rb           # Position tracking and API integration
├── day_trading_position_manager.rb # Day trading position management
└── futures_executor.rb            # Order execution and risk management
```

## Core Trading Services

### DayTradingPositionManager

**Purpose**: Manages day trading positions with automatic same-day closure and risk management.

**Key Responsibilities**:
- Automatic position closure based on time limits
- Take profit/stop loss monitoring and execution
- Position summary and PnL calculation
- Risk management and emergency closure

**Main Methods**:

#### Position Closure Methods
```ruby
# Close expired positions (opened yesterday)
def close_expired_positions
  positions = positions_needing_closure
  # ... closure logic
end

# Close positions approaching closure time (within 30 minutes of 24 hours)
def close_approaching_positions
  positions = positions_approaching_closure
  # ... closure logic
end

# Emergency closure of all day trading positions
def force_close_all_day_trading_positions
  positions = Position.open_day_trading_positions
  # ... emergency closure logic
end
```

#### Risk Management Methods
```ruby
# Check for take profit/stop loss triggers
def check_tp_sl_triggers
  positions = Position.open_day_trading_positions
  # ... TP/SL checking logic
end

# Close positions that hit TP/SL
def close_tp_sl_positions
  triggered_positions = check_tp_sl_triggers
  # ... TP/SL closure logic
end
```

#### Monitoring Methods
```ruby
# Get current market prices for all open positions
def get_current_prices
  positions = Position.open_day_trading_positions
  # ... price fetching logic
end

# Calculate total PnL for all open positions
def calculate_total_pnl
  positions = Position.open_day_trading_positions
  # ... PnL calculation logic
end

# Get comprehensive position summary
def get_position_summary
  {
    open_count: open_positions.count,
    closed_today_count: closed_today.count,
    total_open_value: open_positions.sum(:size),
    total_pnl: total_pnl,
    positions_needing_closure: positions_needing_closure.count,
    positions_approaching_closure: positions_approaching_closure.count
  }
end
```

**Configuration**:
- Logger injection for consistent logging
- Integration with CoinbasePositions service
- Integration with FuturesContractManager for contract data

**Error Handling**:
- Graceful failure per position
- Continues processing other positions if one fails
- Detailed logging for troubleshooting
- Fallback to local position updates on API failures

### CoinbasePositions

**Purpose**: Handles position tracking and API integration with Coinbase Advanced Trade API.

**Key Responsibilities**:
- Position opening and closing via Coinbase API
- Position status synchronization
- Error handling and retry logic

**Main Methods**:
```ruby
# Close a position in Coinbase
def close_position(product_id:, size:)
  # API call to close position
  # Returns success/failure result
end

# Open a new position
def open_position(product_id:, side:, size:, price:)
  # API call to open position
  # Returns position details
end
```

**Integration Points**:
- Coinbase Advanced Trade API
- Local position model updates
- Error handling and logging

### FuturesExecutor

**Purpose**: Handles order execution and risk management for futures trading.

**Key Responsibilities**:
- Order placement and management
- Risk controls and position sizing
- Execution monitoring and reporting

**Note**: This service is referenced in the architecture but implementation details are not shown in the current branch.

## Day Trading Rules and Compliance

### Regulatory Requirements
- **Same-Day Closure**: All day trading positions must be closed before the end of the trading day
- **24-Hour Limit**: Maximum position duration for day trading positions
- **Risk Management**: Automatic take profit/stop loss execution

### Position Lifecycle
1. **Position Opening**: Position created with day_trading flag set
2. **Active Trading**: Position monitored for TP/SL triggers
3. **Approaching Closure**: Warning when position approaches 24-hour limit
4. **Automatic Closure**: Position closed automatically at end of day
5. **Cleanup**: Old closed positions removed after configurable retention period

### Risk Controls
- **Take Profit**: Automatic position closure when profit target reached
- **Stop Loss**: Automatic position closure when loss limit reached
- **Time-Based Closure**: Automatic closure based on regulatory time limits
- **Emergency Closure**: Force closure capability for risk management

## Rake Tasks

The trading system provides comprehensive command-line tools for position management:

### Position Monitoring
```bash
# Check current position status
bundle exec rake day_trading:check_positions

# Get current PnL
bundle exec rake day_trading:pnl

# Show detailed position information
bundle exec rake day_trading:details
```

### Position Management
```bash
# Close expired positions
bundle exec rake day_trading:close_expired

# Close approaching positions
bundle exec rake day_trading:close_approaching

# Check TP/SL triggers
bundle exec rake day_trading:check_tp_sl

# Force close all positions
bundle exec rake day_trading:force_close_all
```

### Maintenance
```bash
# Clean up old positions
bundle exec rake day_trading:cleanup

# Run full management cycle
bundle exec rake day_trading:manage
```

### Non-Interactive Mode
For automated environments, use the `FORCE=true` flag:
```bash
FORCE=true bundle exec rake day_trading:force_close_all
FORCE=true bundle exec rake day_trading:cleanup
```

## Testing

The trading services include comprehensive test coverage:

- **Unit Tests**: Individual service method testing
- **Integration Tests**: API integration testing with VCR cassettes
- **Rake Task Tests**: Command-line tool testing
- **Model Tests**: Position model validation and scopes

## Configuration

### Environment Variables
- `DATABASE_URL`: Database connection for position storage
- `COINBASE_API_KEY`: Coinbase API credentials
- `COINBASE_API_SECRET`: Coinbase API secret
- `COINBASE_PASSPHRASE`: Coinbase API passphrase

### Job Scheduling
- **DayTradingPositionManagementJob**: Every 15 minutes (configurable)
- **EndOfDayPositionClosureJob**: Daily at midnight UTC (configurable)

### Risk Parameters
- **Closure Warning**: 30 minutes before 24-hour limit
- **Position Retention**: 30 days (configurable)
- **Queue Priority**: Critical queue for risk management jobs

## Monitoring and Alerting

### Position Monitoring
- Real-time position status tracking
- PnL calculation and monitoring
- Closure time warnings
- Risk metric reporting

### Job Monitoring
- Job execution status tracking
- Error logging and alerting
- Performance metrics
- Queue depth monitoring

### Health Checks
- Position closure verification
- API connectivity monitoring
- Database health monitoring
- Regulatory compliance verification
