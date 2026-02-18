# Coinbase Futures Bot

[![CI Status](https://github.com/Skeyelab/coinbase_futures_bot/workflows/CI/badge.svg)](https://github.com/Skeyelab/coinbase_futures_bot/actions)

**Status**: ✅ Production-Ready | **Framework**: Rails 8.0 | **Language**: Ruby 3.2.2

A fully-featured automated cryptocurrency futures trading bot with AI-powered chat interface, real-time market data, multi-timeframe signal generation, sentiment analysis, and comprehensive risk management.

**Repository**: [https://github.com/Skeyelab/coinbase_futures_bot](https://github.com/Skeyelab/coinbase_futures_bot)

## Features

- **🤖 AI-Powered Chat Interface**: Natural language command processing with OpenRouter (Claude 3.5) and ChatGPT fallback
- **Multi-timeframe Trading Strategies**: 1h trend analysis, 15m confirmation, 5m entry signals, 1m micro-timing
- **Real-time Market Data**: WebSocket integration with Coinbase spot and futures APIs
- **🔔 Real-Time Signal Generation**: Live trading signals based on real-time market data with WebSocket broadcasting
- **Trading Control**: Start/stop trading, emergency stop, position sizing through chat interface
- **Sentiment Analysis**: News sentiment integration with CryptoPanic API and lexicon-based scoring
- **Risk Management**: Position sizing, stop losses, take profits, and futures contract management
- **Paper Trading**: Comprehensive simulation and backtesting framework
- **Background Processing**: Reliable job processing with GoodJob and PostgreSQL
- **REST & WebSocket APIs**: Full API access to signals, statistics, and real-time updates
- **Comprehensive Testing**: Full test suite with VCR for API interactions
- **Security & Audit**: Comprehensive logging and compliance tracking for trading operations

## Technology Stack

- **Framework**: Rails 8.0 (API-only)
- **Language**: Ruby 3.2.2
- **Database**: PostgreSQL with time-series optimizations
- **Jobs**: GoodJob with cron scheduling
- **AI Services**: OpenRouter (Claude 3.5 Sonnet), OpenAI (GPT-4)
- **Testing**: RSpec with comprehensive coverage
- **APIs**: Coinbase Advanced Trade, Exchange API, CryptoPanic

## Testing & Code Coverage

This project maintains a comprehensive test suite with **141 test examples** covering all critical functionality.

### Coverage Reports

- **Local**: Generated automatically when running tests with SimpleCov
- **HTML Report**: View detailed coverage at `coverage/index.html`
- **CI Coverage**: Coverage data is generated in CI and available as artifacts

### Running Tests with Coverage

```bash
# Run tests with coverage reporting
COVERAGE=true bundle exec rspec

# View local HTML coverage report
open coverage/index.html

# Or use the provided script
./bin/view-coverage
```

### Random Test Execution

Tests are configured to run in random order to catch hidden dependencies and ensure test independence:

```bash
# Tests run in random order by default
bundle exec rspec

# Run with specific seed for debugging
bundle exec rspec --seed 12345

# Run without randomization (for debugging)
bundle exec rspec --order defined
```

For detailed information about random test execution, see [docs/RANDOM_TEST_EXECUTION.md](docs/RANDOM_TEST_EXECUTION.md).

### Coverage Scope

The test suite focuses on the most critical components:

- **Real-time Signal System**: WebSocket broadcasting, signal evaluation, and background processing
- **Background Jobs**: Comprehensive testing of all scheduled jobs and error handling
- **API Controllers**: Full REST API endpoint testing with authentication
- **Market Data Integration**: WebSocket subscriber testing with VCR-recorded API responses
- **Risk Management**: Position sizing, stop losses, and trade execution validation

### Coverage in CI

Coverage data is automatically generated during CI runs and available as downloadable artifacts. The CI workflow:

1. Runs the full test suite with SimpleCov enabled
2. Generates coverage reports and HTML output
3. Uploads coverage artifacts for download
4. Displays coverage percentage in the workflow logs

## Prerequisites

- Ruby 3.2.2 (managed via `.ruby-version`)
- PostgreSQL database
- Bundler gem manager
- Coinbase API credentials (API key + secret)
- CryptoPanic API token (for sentiment analysis)

See [Development Guide](docs/development.md) for detailed setup instructions.

## Quick Reference

### Starting the Bot
```bash
# 1. Start Rails server
bin/rails server

# 2. Access GoodJob dashboard
open http://localhost:3000/good_job

# 3. Start AI chat interface
bin/rails chat_bot:start

# 4. Start real-time signal system
bin/rake realtime:signals
```

### Running Tests
```bash
# Full test suite with coverage
COVERAGE=true bundle exec rspec

# View coverage report
open coverage/index.html

# Run specific test file
bundle exec rspec spec/services/chat_bot_service_spec.rb
```

### Common Operations
```bash
# Check system health
curl http://localhost:3000/up

# View active signals
curl "http://localhost:3000/signals/active"

# Check positions
bin/rake day_trading:check_positions

# Emergency stop all trading
FORCE=true bin/rake realtime:cancel_all
```

## 📚 Documentation

- **[Architecture Overview](docs/architecture.md)** - System design and component relationships
- **[Development Guide](docs/development.md)** - Setup, workflow, and debugging
- **[Configuration](docs/configuration.md)** - Environment variables and settings
- **[API Documentation](docs/api-endpoints.md)** - REST endpoints and examples
- **[Trading Strategies](docs/strategies.md)** - Strategy implementation and tuning
- **[Database Schema](docs/database-schema.md)** - Models and relationships
- **[Background Jobs](docs/jobs.md)** - Job system and scheduling
- **[Testing Guide](docs/testing.md)** - Testing strategies and coverage
- **[Deployment Guide](docs/deployment.md)** - Production deployment and operations
- **[Services Documentation](docs/services/)** - Core business logic components
- **[Day Trading System](docs/day-trading.md)** - Day trading position management and compliance

## Core Commands

### Market Data Collection
```bash
# Subscribe to real-time market data
bin/rake market_data:subscribe[BTC-USD]
PRODUCT_IDS=BTC-USD,ETH-USD bin/rake market_data:subscribe

# Backfill historical candle data
bin/rake market_data:backfill_candles[7]  # 7 days of data
bin/rake market_data:backfill_1h_candles[30]  # 30 days of hourly data
```

### Trading Operations
```bash
# Generate trading signals (batch mode)
bin/rake signals:generate

# Execute paper trading step
bin/rake paper:step

# Day trading position management
bin/rake day_trading:check_positions    # Check position status
bin/rake day_trading:pnl               # View current PnL
bin/rake day_trading:close_expired     # Close expired positions
bin/rake day_trading:check_tp_sl       # Check take profit/stop loss
bin/rake day_trading:force_close_all   # Emergency close all positions
bin/rake day_trading:manage            # Run full management cycle

# View sentiment data
curl "http://localhost:3000/sentiment/aggregates?symbol=BTC-USD&limit=5"
```

### AI-Powered Chat Interface 🤖

The bot includes a comprehensive AI-powered chat interface for natural language interaction:

```bash
# Start the interactive chat interface
bin/rails chat_bot:start

# Resume your last session
bin/rails chat_bot:start --resume

# Example natural language commands:
FuturesBot> show my positions
FuturesBot> what signals are active?
FuturesBot> start trading
FuturesBot> emergency stop
FuturesBot> BTC price
FuturesBot> help
```

**Key Features:**
- **Natural Language Processing**: Uses OpenRouter (Claude 3.5) with ChatGPT fallback
- **Trading Control**: Start/stop operations, emergency stop, position management
- **Persistent Memory**: Cross-session conversation history with profit-focused scoring
- **Comprehensive Audit**: Security logging for compliance and operational tracking
- **Multi-Session Support**: Resume conversations across different sessions

### Real-Time Signal System 🔔

The bot now supports **real-time trade signal generation** based on live market data. Here's how to use it:

#### Quick Start - Get Real-Time Signals

**1. Setup Your Trading Capital:**
```bash
# Set your equity amount (e.g., $1000 for conservative trading)
export SIGNAL_EQUITY_USD=1000

# Optional: Adjust risk per trade (default is 1% of equity)
export REALTIME_SIGNAL_MIN_CONFIDENCE=65  # Minimum 65% confidence signals
```

**2. Start the Real-Time System:**
```bash
# Start complete real-time system (market data + signal evaluation)
bin/rake realtime:signals

# Or start only signal evaluation (if market data already running)
bin/rake realtime:signal_job
```

**2. Get Real-Time Signals via API:**
```bash
# Get active signals
curl "http://localhost:3000/signals/active"

# Get high-confidence signals only
curl "http://localhost:3000/signals/high_confidence?threshold=70"

# Get recent signals (last hour)
curl "http://localhost:3000/signals/recent?hours=1"

# Get signal statistics
curl "http://localhost:3000/signals/stats"

# Manual signal evaluation
curl -X POST "http://localhost:3000/signals/evaluate"
```

**3. Real-Time WebSocket Updates:**
Connect to WebSocket for live signal alerts:
```javascript
// Connect to signals channel
const ws = new WebSocket('ws://localhost:3000/cable');
ws.onopen = () => {
  ws.send(JSON.stringify({
    command: 'subscribe',
    identifier: JSON.stringify({ channel: 'SignalsChannel' })
  }));
};
ws.onmessage = (event) => {
  const data = JSON.parse(event.data);
  if (data.type === 'signal_alert') {
    console.log('New signal:', data.signal);
  }
};
```

#### Real-Time Signal Features

- **🔴 Live Market Data**: WebSocket connections to Coinbase for real-time price updates
- **📊 Real-Time Candles**: Continuous OHLCV candle aggregation from live ticks
- **🚀 Instant Signals**: Signals generated within seconds of market conditions being met
- **📡 WebSocket Broadcasting**: Real-time signal alerts via Action Cable
- **🎛️ REST API**: Full API access to signals and statistics
- **⚙️ Configurable**: Adjustable confidence thresholds, evaluation intervals, and filters

#### Configuration

Set these environment variables for customization:

```bash
# Signal evaluation settings
REALTIME_SIGNAL_EVALUATION_INTERVAL=30    # How often to check for signals (seconds)
REALTIME_SIGNAL_MIN_CONFIDENCE=60         # Minimum confidence threshold (0-100)
REALTIME_SIGNAL_MAX_PER_HOUR=10           # Rate limiting: max signals per hour
REALTIME_SIGNAL_DEDUPE_WINDOW=300         # Duplicate prevention window (seconds)

# Broadcasting settings
SIGNAL_BROADCAST_ENABLED=true             # Enable WebSocket broadcasting
SIGNALS_API_KEY=your_api_key              # API authentication key

# Candle aggregation
CANDLE_AGGREGATION_ENABLED=true           # Enable real-time candle updates
```

#### Real-Time Signal Flow

```
WebSocket Price Ticks → Real-Time Candle Aggregation → Strategy Evaluation → Signal Generation → Broadcast
          ↓                        ↓                           ↓                     ↓              ↓
     Coinbase API             1m/5m/15m/1h Candles         Multi-Timeframe       SignalAlert     WebSocket/API
     Live Data                Updated Every Tick           Analysis           Database Record    Clients
```

#### Available Real-Time Commands

```bash
# Start real-time signal system
bin/rake realtime:signals

# Evaluate signals once for all pairs
bin/rake realtime:evaluate

# Evaluate signals for specific symbol
bin/rake realtime:evaluate_symbol[BTC-USD]

# View real-time signal statistics
bin/rake realtime:stats

# Clean up expired signal alerts
bin/rake realtime:cleanup

# Cancel all active signals (emergency stop)
FORCE=true bin/rake realtime:cancel_all
```

### 💰 10-Contract Trading Setup (Your Comfort Zone)

For traders comfortable with 10+ contract exposure, here's the optimized configuration:

#### 1. Capital & Risk Configuration
```bash
# Set your account size (matches your risk tolerance)
export SIGNAL_EQUITY_USD=5000

# Balanced risk settings for 10-contract trading
export REALTIME_SIGNAL_MIN_CONFIDENCE=65     # Quality signals (not too restrictive)
export REALTIME_SIGNAL_MAX_PER_HOUR=8        # Allows decent frequency
export REALTIME_SIGNAL_EVALUATION_INTERVAL=45 # Check every 45 seconds

# Risk management for larger positions
export STRATEGY_RISK_FRACTION=0.02           # 2% risk per trade ($100 max loss)
export STRATEGY_TP_TARGET=0.006              # 60 bps take profit ($60 target)
export STRATEGY_SL_TARGET=0.004              # 40 bps stop loss ($40 max loss)
```

#### 2. Position Size Calculation
With $5000 equity and 2% risk per trade:
- **Max loss per trade**: $100
- **Typical BTC/ETH futures contract**: $100/contract
- **Your comfort zone**: 10 contracts ($1000 exposure)
- **Daily risk budget**: $800 (8 trades × $100)
- **Position sizes**: 5-15 contracts ($500-$1500 exposure)

#### 3. Futures Contract Selection
```bash
# Recommended for small accounts:
# - BIT-29AUG25-CDE (BTC futures, $100/contract)
# - ET-29AUG25-CDE (ETH futures, $100/contract)
#
# Avoid:
# - BTC-USD (spot) - requires full BTC purchase
# - High-leverage products
```

#### 4. Start Trading
```bash
# 1. Sync latest market data
bin/rake market_data:upsert_futures_products

# 2. Backfill recent candle data (1-2 days)
bin/rake market_data:backfill_1h_candles[2]
bin/rake market_data:backfill_15m_candles[2]
bin/rake market_data:backfill_5m_candles[1]

# 3. Start real-time system
SIGNAL_EQUITY_USD=5000 bin/rake realtime:signals

# 4. Monitor signals in another terminal
curl "http://localhost:3000/signals/active" | jq .
```

#### 5. Monitor & Manage
```bash
# Check signal statistics
bin/rake realtime:stats

# View active signals
curl "http://localhost:3000/signals/active"

# View signal history
curl "http://localhost:3000/signals/recent?hours=24"

# Emergency stop
FORCE=true bin/rake realtime:cancel_all
```

#### Risk Management Rules for 10-Contract Trading

1. **5-15 contracts per trade** - Matches your $1000 exposure comfort zone
2. **65%+ confidence signals only** - Quality trades with good frequency
3. **Max 8 signals per hour** - Allows active trading without overtrading
4. **Daily loss limit: $250** - Stop if you lose 5% of capital
5. **Weekly review** - Assess performance and adjust strategy
6. **Monitor correlation** - Don't hold both BTC and ETH positions simultaneously

#### Expected Performance
- **Win rate target**: 60%+ (conservative estimate)
- **Average win**: $60 (take profit on 10 contracts)
- **Average loss**: $40 (stop loss on 10 contracts)
- **Expected daily return**: $10-30 (after fees)
- **Monthly target**: $300-900 (6-18% return)
- **Position sizes**: $500-$1500 per trade

### Monitoring
```bash
# GoodJob dashboard (development)
open http://localhost:3000/good_job

# Health check
curl http://localhost:3000/up
```

## Key Features

### 🤖 Multi-Timeframe Strategy
- **1h Analysis**: Primary trend identification using EMA crossovers
- **15m Confirmation**: Intraday trend validation
- **5m Entry Signals**: Pullback and momentum-based entries
- **1m Micro-timing**: Precise entry and exit execution

### 📊 Sentiment Integration
- **News Analysis**: CryptoPanic API integration with lexicon-based scoring
- **Z-Score Filtering**: Statistical normalization for signal gating
- **Real-time Processing**: Continuous sentiment aggregation and analysis

### ⚡ Background Processing
- **Data Collection**: Automated OHLCV candle fetching and WebSocket streaming
- **Signal Generation**: Scheduled strategy execution and position analysis
- **Risk Management**: Automated stop-loss, take-profit, and position sizing

### 🧪 Paper Trading & Backtesting
- **Simulation Engine**: Comprehensive paper trading with realistic execution
- **Strategy Calibration**: Automated parameter optimization
- **Performance Analytics**: Detailed trade analysis and metrics

### 📈 Day Trading Position Management
- **Automatic Closure**: Same-day position closure for regulatory compliance
- **Risk Management**: Take profit/stop loss monitoring and execution
- **24-Hour Limits**: Enforced maximum position duration for day trading
- **Real-time Monitoring**: Live PnL tracking and position status updates
- **Emergency Controls**: Force closure capabilities for risk management

## Production Deployment

### Environment Configuration
```bash
# Required production variables
export RAILS_ENV=production
export SECRET_KEY_BASE=your_secret_key
export DATABASE_URL=postgresql://user:pass@host:port/db
export COINBASE_API_KEY=production_key
export COINBASE_API_SECRET=production_secret
export CRYPTOPANIC_TOKEN=production_token

# Feature flags
export SENTIMENT_ENABLE=true
export SENTIMENT_Z_THRESHOLD=1.5
```

### Worker Process
```bash
# Dedicated worker (recommended for production)
RAILS_ENV=production bundle exec good_job start
```

## Project Status & Roadmap

This project is **feature-complete and production-ready**. For a comprehensive list of implemented features and future enhancements, see:

- **[TODO.md](TODO.md)** - Prioritized work items and future enhancements
- **[Development Guide](docs/development.md)** - Setup, workflow, and coding standards
- **GitHub Issues** - Bug reports and feature requests

### Key Metrics
- ✅ **80+ test files** with 1000+ test examples
- ✅ **25 background jobs** for automated trading operations
- ✅ **40+ services** implementing business logic
- ✅ **11 models** for data persistence
- ✅ **Comprehensive documentation** in docs/ directory

## Contributing

This project follows GitHub Flow:

1. **Create Feature Branch**: `git checkout -b feature/description`
2. **Make Changes**: Follow coding standards and write tests
3. **Run Tests**: `bundle exec rspec && bin/standardrb`
4. **Submit PR**: All CI checks must pass (StandardRB, Brakeman, RSpec)

See [Development Guide](docs/development.md) for detailed workflow.

## Security & Risk Management

⚠️ **Important**: This is financial trading software. Always:
- Test thoroughly in paper trading mode before live deployment
- Implement proper API key security and rotation
- Monitor position sizes and risk limits
- Use appropriate stop-losses and position sizing
- Understand the risks of automated trading

## Support and Documentation

- 📖 **Full Documentation**: See [docs/](docs/) directory
- 🐛 **Issues**: Use GitHub Issues for bug reports
- 💬 **Discussions**: Use GitHub Discussions for questions
- 📝 **Project Planning**: Tracked in Linear (FuturesBot project)

## License

This project is private. All rights reserved.
