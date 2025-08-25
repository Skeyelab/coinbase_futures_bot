# Day Trading Position Management System

## Overview

The Day Trading Position Management System is a comprehensive solution for managing day trading positions with automatic same-day closure, risk management, and regulatory compliance. This system ensures that all day trading positions are properly managed according to trading regulations and risk parameters.

## Key Features

### 🕐 Automatic Position Closure
- **Same-Day Closure**: All day trading positions automatically closed before end of trading day
- **24-Hour Limit**: Maximum position duration enforced with automatic closure
- **Warning System**: Alerts when positions approach closure time (30 minutes before limit)

### 🎯 Risk Management
- **Take Profit**: Automatic position closure when profit targets are reached
- **Stop Loss**: Automatic position closure when loss limits are hit
- **Emergency Closure**: Force closure capability for risk management scenarios

### 📊 Position Monitoring
- **Real-Time PnL**: Live profit/loss calculation for all open positions
- **Position Summary**: Comprehensive overview of position status and metrics
- **Closure Tracking**: Monitoring of positions needing closure or approaching limits

### 🔄 Automated Management
- **Background Jobs**: Scheduled position management every 15 minutes
- **End-of-Day Cleanup**: Automatic closure of all remaining positions
- **Rake Tasks**: Command-line tools for manual position management

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                Day Trading Position Manager                 │
├─────────────────────────────────────────────────────────────┤
│  • Position Closure Logic                                  │
│  • Risk Management                                         │
│  • PnL Calculation                                         │
│  • Market Price Integration                                │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                Background Jobs                              │
├─────────────────────────────────────────────────────────────┤
│  • DayTradingPositionManagementJob (every 15 min)         │
│  • EndOfDayPositionClosureJob (daily at midnight)         │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                Rake Tasks                                   │
├─────────────────────────────────────────────────────────────┤
│  • Position monitoring and management                      │
│  • Manual closure operations                               │
│  • Cleanup and maintenance                                 │
└─────────────────────────────────────────────────────────────┘
```

## Core Components

### 1. Position Model

The `Position` model provides the foundation for position tracking:

```ruby
class Position < ApplicationRecord
  # Validations
  validates :product_id, presence: true
  validates :side, presence: true, inclusion: { in: %w[LONG SHORT] }
  validates :size, presence: true, numericality: { greater_than: 0 }
  validates :entry_price, presence: true, numericality: { greater_than: 0 }
  validates :entry_time, presence: true
  validates :status, presence: true, inclusion: { in: %w[OPEN CLOSED] }
  validates :day_trading, inclusion: { in: [true, false] }

  # Key scopes
  scope :open, -> { where(status: "OPEN") }
  scope :closed, -> { where(status: "CLOSED") }
  scope :day_trading, -> { where(day_trading: true) }
  scope :opened_today, -> { where("DATE(entry_time) = ?", Date.current) }
  scope :opened_yesterday, -> { where("entry_time < ? AND entry_time >= ?", 24.hours.ago, 48.hours.ago) }
  scope :positions_needing_closure, -> { day_trading.open.opened_yesterday }
  scope :positions_approaching_closure, -> { day_trading.open.where("entry_time < ?", 23.hours.ago) }
end
```

**Key Methods**:
- `needs_same_day_closure?` - Check if position needs immediate closure
- `needs_closure_soon?` - Check if approaching 24-hour limit
- `calculate_pnl(current_price)` - Calculate unrealized PnL
- `hit_take_profit?(current_price)` - Check take profit trigger
- `hit_stop_loss?(current_price)` - Check stop loss trigger
- `close_position!(close_price, close_time)` - Normal position closure
- `force_close!(close_price, reason, close_time)` - Emergency closure

### 2. Day Trading Position Manager

The core service for managing day trading positions:

```ruby
class DayTradingPositionManager
  def initialize(logger: Rails.logger)
    @logger = logger
    @positions_service = CoinbasePositions.new(logger: logger)
    @contract_manager = MarketData::FuturesContractManager.new(logger: logger)
  end

  # Position closure methods
  def close_expired_positions
    # Close positions opened yesterday
  end

  def close_approaching_positions
    # Close positions approaching 24-hour limit
  end

  def force_close_all_day_trading_positions
    # Emergency closure of all positions
  end

  # Risk management methods
  def check_tp_sl_triggers
    # Check for take profit/stop loss triggers
  end

  def close_tp_sl_positions
    # Close positions that hit TP/SL
  end

  # Monitoring methods
  def get_position_summary
    # Comprehensive position overview
  end

  def calculate_total_pnl
    # Total PnL for all open positions
  end
end
```

### 3. Background Jobs

Automated position management through scheduled jobs:

#### DayTradingPositionManagementJob
- **Schedule**: Every 15 minutes
- **Purpose**: Regular position monitoring and management
- **Functions**: Close expired positions, check TP/SL, provide summaries

#### EndOfDayPositionClosureJob
- **Schedule**: Daily at midnight UTC
- **Purpose**: Force closure of all remaining day trading positions
- **Critical**: Ensures regulatory compliance

### 4. Rake Tasks

Comprehensive command-line tools for position management:

```bash
# Position monitoring
bundle exec rake day_trading:check_positions
bundle exec rake day_trading:pnl
bundle exec rake day_trading:details

# Position management
bundle exec rake day_trading:close_expired
bundle exec rake day_trading:close_approaching
bundle exec rake day_trading:check_tp_sl
bundle exec rake day_trading:force_close_all

# Maintenance
bundle exec rake day_trading:cleanup
bundle exec rake day_trading:manage
```

## Day Trading Rules

### Regulatory Compliance

1. **Same-Day Closure**: All day trading positions must be closed before the end of the trading day
2. **24-Hour Limit**: Maximum position duration for day trading positions
3. **Risk Management**: Automatic take profit/stop loss execution required

### Position Lifecycle

```
Position Opened
      │
      ▼
  Active Trading
      │
      ▼
TP/SL Monitoring
      │
      ▼
Approaching Closure (23.5 hours)
      │
      ▼
Automatic Closure (24 hours)
      │
      ▼
Position Closed
      │
      ▼
Cleanup (30 days retention)
```

### Risk Controls

- **Take Profit**: Automatic closure when profit target reached
- **Stop Loss**: Automatic closure when loss limit hit
- **Time-Based Closure**: Automatic closure based on regulatory time limits
- **Emergency Closure**: Force closure capability for risk management

## Configuration

### Environment Variables

```bash
# Database
DATABASE_URL=postgresql://user:pass@localhost/coinbase_futures_bot

# Coinbase API
COINBASE_API_KEY=your_api_key
COINBASE_API_SECRET=your_api_secret
COINBASE_PASSPHRASE=your_passphrase

# Job Scheduling (optional)
DAY_TRADING_MANAGEMENT_CRON="*/15 * * * *"
END_OF_DAY_CLOSURE_CRON="0 0 * * *"
```

### Risk Parameters

```ruby
# Position closure timing
CLOSURE_WARNING_HOURS = 23.5  # Warning 30 minutes before limit
MAX_POSITION_DURATION = 24    # Maximum hours for day trading

# Position retention
POSITION_RETENTION_DAYS = 30  # Days to keep closed positions

# Queue priorities
DAY_TRADING_QUEUE = :critical  # High priority for risk management
```

## Usage Examples

### Basic Position Management

```ruby
# Initialize manager
manager = Trading::DayTradingPositionManager.new

# Check current status
summary = manager.get_position_summary
puts "Open positions: #{summary[:open_count]}"
puts "Total PnL: #{summary[:total_pnl]}"

# Close expired positions
if manager.positions_need_closure?
  closed_count = manager.close_expired_positions
  puts "Closed #{closed_count} expired positions"
end
```

### Risk Management

```ruby
# Check for TP/SL triggers
triggered_positions = manager.check_tp_sl_triggers

if triggered_positions.any?
  puts "Found #{triggered_positions.size} triggered positions"

  # Close triggered positions
  closed_count = manager.close_tp_sl_positions
  puts "Closed #{closed_count} TP/SL positions"
end
```

### Emergency Operations

```ruby
# Force close all day trading positions
if manager.positions_need_closure?
  closed_count = manager.force_close_all_day_trading_positions
  puts "Emergency closed #{closed_count} positions"
end
```

## Monitoring and Alerting

### Position Monitoring

- **Real-time Status**: Live position status tracking
- **PnL Tracking**: Continuous profit/loss monitoring
- **Closure Warnings**: Alerts for positions approaching limits
- **Risk Metrics**: Comprehensive risk reporting

### Job Monitoring

- **Execution Status**: Job success/failure tracking
- **Performance Metrics**: Job execution time and throughput
- **Error Alerting**: Immediate notification of failures
- **Queue Monitoring**: Job queue depth and processing

### Health Checks

- **Position Closure**: Verification of closure operations
- **API Connectivity**: Coinbase API health monitoring
- **Database Health**: Position data integrity checks
- **Regulatory Compliance**: Day trading rule verification

## Testing

The system includes comprehensive test coverage:

### Test Categories

- **Unit Tests**: Individual service method testing
- **Integration Tests**: API integration with VCR cassettes
- **Rake Task Tests**: Command-line tool functionality
- **Model Tests**: Position model validation and scopes
- **Job Tests**: Background job execution testing

### Test Coverage

- Position lifecycle management
- Risk management functionality
- API integration error handling
- Rake task execution
- Background job processing

## Troubleshooting

### Common Issues

1. **Positions Not Closing**
   - Check job scheduling and execution
   - Verify API connectivity
   - Review position status and timing

2. **TP/SL Not Triggering**
   - Verify price data availability
   - Check take profit/stop loss values
   - Review trigger logic

3. **Job Failures**
   - Check job logs for errors
   - Verify database connectivity
   - Review API rate limits

### Debug Commands

```bash
# Check job status
bundle exec rake day_trading:check_positions

# View detailed logs
tail -f log/development.log | grep "DayTradingPositionManager"

# Test API connectivity
bundle exec rake day_trading:pnl

# Force cleanup
FORCE=true bundle exec rake day_trading:cleanup
```

## Future Enhancements

### Planned Features

- **Position Sizing**: Dynamic position sizing based on risk
- **Portfolio Management**: Multi-position risk management
- **Advanced Alerts**: Customizable notification system
- **Performance Analytics**: Historical performance tracking
- **Backtesting**: Strategy backtesting capabilities

### Integration Opportunities

- **Risk Management**: Integration with external risk systems
- **Compliance**: Enhanced regulatory reporting
- **Analytics**: Integration with trading analytics platforms
- **Notifications**: Slack/email alert integration

## Support

For questions or issues with the Day Trading Position Management System:

1. **Documentation**: Review this guide and related documentation
2. **Logs**: Check application logs for detailed error information
3. **Testing**: Use rake tasks to verify system functionality
4. **Development**: Review source code and test coverage

## Related Documentation

- [Trading Services](services/trading.md) - Detailed service documentation
- [Database Schema](database-schema.md) - Position table structure
- [Background Jobs](jobs.md) - Job scheduling and execution
- [API Endpoints](api-endpoints.md) - Position management endpoints
