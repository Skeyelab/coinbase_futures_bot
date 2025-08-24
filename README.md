# Coinbase Futures Bot

[![CI Status](https://github.com/Skeyelab/coinbase_futures_bot/workflows/CI/badge.svg)](https://github.com/Skeyelab/coinbase_futures_bot/actions)

An automated cryptocurrency futures trading bot built with Rails 7.2, featuring real-time market data ingestion, multi-timeframe signal generation, sentiment analysis, and risk management.

**Repository**: [https://github.com/Skeyelab/coinbase_futures_bot](https://github.com/Skeyelab/coinbase_futures_bot)

## Features

- **Multi-timeframe Trading Strategies**: 1h trend analysis, 15m confirmation, 5m entry signals, 1m micro-timing
- **Real-time Market Data**: WebSocket integration with Coinbase spot and futures APIs
- **Sentiment Analysis**: News sentiment integration with CryptoPanic API and lexicon-based scoring
- **Risk Management**: Position sizing, stop losses, take profits, and futures contract management
- **Paper Trading**: Comprehensive simulation and backtesting framework
- **Background Processing**: Reliable job processing with GoodJob and PostgreSQL
- **Comprehensive Testing**: Full test suite with VCR for API interactions

## Technology Stack

- **Framework**: Rails 7.2 (API-only)
- **Language**: Ruby 3.2.4
- **Database**: PostgreSQL with time-series optimizations
- **Jobs**: GoodJob with cron scheduling
- **Testing**: RSpec with comprehensive coverage
- **APIs**: Coinbase Advanced Trade, Exchange API, CryptoPanic

## Prerequisites
- Ruby 3.2.x (RVM recommended; repo uses `.ruby-version`)
- PostgreSQL (DATABASE_URL)
- Bundler

## Quick Start

### 1. Setup Environment
```bash
# Clone and setup Ruby environment
git clone git@github.com:Skeyelab/coinbase_futures_bot.git
cd coinbase_futures_bot
rvm use ruby-3.2.4@coinbase_futures_bot --create

# Install dependencies and setup database
bundle install
bin/rails db:prepare
```

### 2. Configure Environment Variables
```bash
# Copy example and edit configuration
cp .env.example .env
# Edit .env with your API credentials
```

Required variables:
- `DATABASE_URL` - PostgreSQL connection string
- `COINBASE_API_KEY` - Coinbase API credentials
- `CRYPTOPANIC_TOKEN` - News sentiment API token

### 3. Start Development Server
```bash
bin/rails server
# Access GoodJob dashboard: http://localhost:3000/good_job
```

### 4. Run Tests
```bash
bundle exec rspec
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

## Core Commands

### Market Data Collection
```bash
# Subscribe to real-time market data
bin/rake market_data:subscribe[BTC-USD-PERP]
PRODUCT_IDS=BTC-USD-PERP,ETH-USD-PERP bin/rake market_data:subscribe

# Backfill historical candle data
bin/rake market_data:backfill_candles[7]  # 7 days of data
bin/rake market_data:backfill_1h_candles[30]  # 30 days of hourly data
```

### Trading Operations
```bash
# Generate trading signals
bin/rake signals:generate

# Execute paper trading step
bin/rake paper:step

# View sentiment data
curl "http://localhost:3000/sentiment/aggregates?symbol=BTC-USD-PERP&limit=5"
```

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

## Contributing

This project follows GitHub Flow with pull requests:

1. **Create Feature Branch**: `git checkout -b feature/description`
2. **Make Changes**: Follow coding standards and write tests
3. **Run Tests**: `bundle exec rspec && bundle exec rubocop`
4. **Submit PR**: All CI checks must pass (RuboCop, Brakeman, RSpec)
5. **Code Review**: Maintain documentation and session notes

See [Development Guide](docs/development.md) for detailed workflow and standards.

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

See LICENSE file for details.
