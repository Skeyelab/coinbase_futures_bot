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
- TUI dashboard, chat, and positions web UI

## Technology Stack
- **Framework**: Rails 8.1 (API-first; HTML UI routes added)
- **Language**: Ruby 3.2.4
- **Database**: PostgreSQL
- **Background Jobs**: GoodJob
- **Testing**: RSpec (~2,400 examples), `bin/parallel_rspec` in CI
- **External APIs**: Coinbase Advanced Trade, CryptoPanic

## Development Workflow
- **Issue Tracking**: [GitHub Issues](https://github.com/Skeyelab/coinbase_futures_bot/issues) (primary)
- **Branch Strategy**: Feature branches with PRs
- **CI/CD**: GitHub Actions (StandardRB, Brakeman, bundler-audit, parallel RSpec)
- **Commit Style**: Conventional Commits

## Key Directories
- `app/` - Rails application code
- `spec/` - Test files
- `db/` - Database schema and migrations
- `lib/` - CLI, TUI, rake tasks
- `docs/` - Developer documentation
- `wiki/` - Operator wiki (synced separately)

## Environment Variables
- `DATABASE_URL` - PostgreSQL connection
- `COINBASE_API_KEY` / `COINBASE_API_SECRET` - Coinbase credentials (or `cdp_api_key.json`)
- `CRYPTOPANIC_TOKEN` - News sentiment API
- `SIGNALS_API_KEY` - Signal API authentication
- `POSITIONS_UI_USERNAME` / `POSITIONS_UI_PASSWORD` - Positions web UI
- Various feature flags — see [docs/configuration.md](docs/configuration.md)

## Quick Start
```bash
git clone git@github.com:Skeyelab/coinbase_futures_bot.git
cd coinbase_futures_bot

rvm use ruby-3.2.4@coinbase_futures_bot --create
bundle install
bin/rails db:prepare

bin/futuresbot          # TUI dashboard
# or
bin/rails server
open http://localhost:3000/jobs
```

## Important Notes
- Futures trading bot — validate in paper mode before live use
- Prefer `AGENTS.md` and `Gemfile.lock` over stale prose docs
- Never commit `cdp_api_key.json` or `.env`
