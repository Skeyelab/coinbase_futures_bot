# Project Metadata

## Repository Information
- **Name**: coinbase_futures_bot
- **Full URL**: https://github.com/Skeyelab/coinbase_futures_bot
- **SSH Clone**: git@github.com:Skeyelab/coinbase_futures_bot.git
- **Owner**: Skeyelab
- **Local Path**: `/Users/edahl/Documents/GitHub/coinbase_futures_bot`

## Project Purpose
Automated futures trading bot for Coinbase with:
- Real-time market data ingestion
- Signal generation and strategy execution
- Risk management and position sizing
- Paper trading simulation
- Sentiment analysis integration

## Technology Stack
- **Framework**: Rails 7.2.x (API-only)
- **Language**: Ruby 3.2.4
- **Database**: PostgreSQL
- **Background Jobs**: GoodJob
- **Testing**: RSpec
- **External APIs**: Coinbase Advanced Trade, CryptoPanic

## Development Workflow
- **Issue Tracking**: Linear (FuturesBot project)
- **Branch Strategy**: Feature branches with PRs
- **CI/CD**: GitHub Actions with RuboCop and Brakeman
- **Commit Style**: Conventional Commits

## Key Directories
- `app/` - Rails application code
- `spec/` - Test files
- `db/` - Database schema and migrations
- `services/` - Business logic
- `lib/tasks/` - Custom Rake tasks

## Environment Variables
- `DATABASE_URL` - PostgreSQL connection
- `COINBASE_API_KEY` - Coinbase API credentials
- `CRYPTOPANIC_TOKEN` - News sentiment API
- Various feature flags and configuration

## Quick Start
```bash
# Clone the repository
git clone git@github.com:Skeyelab/coinbase_futures_bot.git
cd coinbase_futures_bot

# Setup Ruby environment
rvm use ruby-3.2.2@coinbase_futures_bot --create

# Install dependencies
bundle install

# Setup database
bin/rails db:prepare

# Start development server
bin/rails s
```

## Important Notes
- This is a **futures trading bot** - use with caution
- Paper trading mode is available for testing
- All production deployments require proper risk management
- Follow the established coding patterns and conventions
