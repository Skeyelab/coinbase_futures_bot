# Coinbase Futures Bot

[![CI Status](https://github.com/Skeyelab/coinbase_futures_bot/workflows/CI/badge.svg)](https://github.com/Skeyelab/coinbase_futures_bot/actions)

**Status**: Actively developed | **Framework**: Rails 8.1 | **Language**: Ruby 3.2.4

Automated cryptocurrency futures trading bot with a full-screen TUI dashboard, AI chat interface, real-time market data, multi-timeframe signal generation, sentiment analysis, swing/day-trading workflows, and risk controls.

**Repository**: [https://github.com/Skeyelab/coinbase_futures_bot](https://github.com/Skeyelab/coinbase_futures_bot)

> **Note:** This is financial trading software. Paper-trade and validate thoroughly before live deployment. For operational truth (versions, routes, env vars), prefer `Gemfile.lock`, `config/routes.rb`, and [AGENTS.md](AGENTS.md) over wiki prose.

## Features

- **Full-Screen TUI Dashboard**: Primary operator interface (`bin/futuresbot`) with positions, signals, live prices, and keyboard shortcuts
- **AI Chat Interface**: Natural language commands via OpenRouter (Claude) with OpenAI fallback
- **Positions Web UI**: Server-rendered HTML at `/positions` (HTTP Basic auth)
- **Multi-Timeframe Strategies**: 1h trend, 15m confirmation, 5m entry, 1m micro-timing
- **Real-Time Market Data**: WebSocket subscribers for Coinbase spot and futures feeds
- **Real-Time Signal Generation**: Live evaluation, deduplication, and Action Cable broadcasting
- **Day & Swing Trading**: Position lifecycle workflows, contract expiry, end-of-day closure, trailing stops
- **Sentiment Analysis**: CryptoPanic plus RSS sources with lexicon scoring
- **Nightly Calibration**: Walk-forward grid search of the live strategy; activates versioned per-symbol TradingProfiles
- **Background Processing**: GoodJob on PostgreSQL with cron scheduling
- **REST & WebSocket APIs**: Signals, sentiment, chat, positions, health checks
- **Observability**: Sentry error/performance monitoring, Slack notifications and commands
- **Testing**: RSpec with VCR (strict HTTP), SimpleCov coverage, parallel CI runs

## Technology Stack

- **Framework**: Rails 8.1 (`config.load_defaults 8.0`; API-only with HTML UI routes added back)
- **Language**: Ruby 3.2.4 (`.ruby-version`)
- **Database**: PostgreSQL
- **Jobs**: GoodJob 4.x with cron scheduling
- **AI Services**: OpenRouter (primary), OpenAI (fallback)
- **Testing**: RSpec 8, FactoryBot, VCR/WebMock, SimpleCov
- **Lint / Security**: StandardRB, Brakeman, bundler-audit
- **APIs**: Coinbase Advanced Trade, Exchange API, CryptoPanic

## Testing & Code Coverage

The suite has **109 spec files** and **~2,400 examples** (run `bundle exec rspec --dry-run` for the current count).

### Running Tests

```bash
# Single file or focused debug
bundle exec rspec spec/services/chat_bot_service_spec.rb

# Full suite (parallel — matches CI)
bin/parallel_rspec

# Full suite with coverage
COVERAGE=true bundle exec rspec

# View HTML coverage report
open coverage/index.html
# or
./bin/view-coverage
```

Tests run in **random order** by default (see [docs/RANDOM_TEST_EXECUTION.md](docs/RANDOM_TEST_EXECUTION.md)):

```bash
bundle exec rspec --seed 12345   # reproduce a seed
bundle exec rspec --order defined # disable randomization
```

### Local TDD

```bash
bundle exec guard   # RSpec-on-change via Guardfile
```

### CI

CI runs StandardRB, Brakeman, bundler-audit, then `bin/parallel_rspec` with `COVERAGE=true`. Coverage artifacts are uploaded from the workflow.

## Prerequisites

- Ruby 3.2.4 (see `.ruby-version`; RVM gemset `ruby-3.2.4@coinbase_futures_bot` recommended)
- PostgreSQL
- Bundler
- **Coinbase credentials** — either:
  - `cdp_api_key.json` at the repo root (preferred for ES256 private keys with real newlines), or
  - `COINBASE_API_KEY` + `COINBASE_API_SECRET` in `.env`
- CryptoPanic token (sentiment; optional if sentiment disabled)
- OpenRouter and/or OpenAI keys (chat interface)

Copy `.env.example` to `.env` for shape only — never commit secrets. See [docs/configuration.md](docs/configuration.md) and [docs/development.md](docs/development.md).

## Quick Reference

### Starting the Bot

The **primary interface** is the full-screen TUI dashboard.

```bash
# TUI dashboard (default command)
bin/futuresbot
bin/futuresbot dashboard

# All-in-one: TUI + market data + signal evaluation
bin/futuresbot start

# Custom refresh interval (seconds)
bin/futuresbot dashboard --refresh 10

# AI chat
bin/futuresbot chat
bin/futuresbot chat --resume

# One-shot CLI summaries
bin/futuresbot status
bin/futuresbot positions
bin/futuresbot signals

# Kill switch
bin/futuresbot halt --reason "manual stop"
bin/futuresbot resume
bin/futuresbot halt_status
```

#### Background services

```bash
# Rails server (API, WebSocket, HTML UI)
bin/rails server

# GoodJob dashboard (development: no auth; production: basic auth)
open http://localhost:3000/jobs

# Real-time signal loop (market data + evaluation)
bin/rake realtime:signals
```

#### Positions web UI

```bash
# Set credentials (not the names in .env.example's "API Authentication" section)
export POSITIONS_UI_USERNAME=your_user
export POSITIONS_UI_PASSWORD=your_password

open http://localhost:3000/positions
```

### Running Tests

```bash
bin/parallel_rspec                              # full suite (CI-style)
bundle exec rspec spec/path/to/file_spec.rb     # single file
COVERAGE=true bundle exec rspec                 # with coverage
bin/standardrb                                  # lint
bin/brakeman --no-pager                         # security scan
```

### Common Operations

```bash
# Health
curl http://localhost:3000/up
curl http://localhost:3000/health

# Active signals (requires SIGNALS_API_KEY when set)
curl -H "X-API-Key: $SIGNALS_API_KEY" http://localhost:3000/signals/active

# Day trading
bin/rake day_trading:check_positions
bin/rake day_trading:manage

# Emergency: cancel active signal alerts
FORCE=true bin/rake realtime:cancel_all
```

## Documentation

- **[TUI Dashboard](docs/tui.md)** — Terminal dashboard and key bindings
- **[Architecture Overview](docs/architecture.md)** — System design
- **[Development Guide](docs/development.md)** — Setup and workflow
- **[Configuration](docs/configuration.md)** — Environment variables
- **[API Documentation](docs/api-endpoints.md)** — REST endpoints
- **[Chat Bot Interface](docs/chat-bot-interface.md)** — AI chat commands
- **[Trading Strategies](docs/strategies.md)** — Strategy logic
- **[Database Schema](docs/database-schema.md)** — Models and relationships
- **[Background Jobs](docs/jobs.md)** — Scheduling
- **[Testing Guide](docs/testing.md)** — RSpec, VCR, coverage
- **[Deployment Guide](docs/deployment.md)** — Production operations
- **[Day Trading](docs/day-trading.md)** — Day-trading lifecycle
- **[Sentry Monitoring](docs/sentry-monitoring.md)** — Error and performance tracking
- **[Slack Integration](docs/slack-integration.md)** — Notifications and slash commands
- **[Services](docs/services/)** — Core business logic

Agent-oriented reference: [AGENTS.md](AGENTS.md)

## Core Commands

### Market Data

```bash
bin/rake market_data:subscribe[BTC-USD]
PRODUCT_IDS=BTC-USD,ETH-USD bin/rake market_data:subscribe
bin/rake market_data:backfill_candles[7]               # enqueue background backfill
bin/rails "market_data:backfill[30,'BTC-USD ETH-USD']"  # inline deep backfill (all TFs; products optional)
bin/rake market_data:upsert_futures_products   # sync contract catalog
```

### Trading & Signals

```bash
bin/rake signals:generate
bin/rake day_trading:check_positions
bin/rake day_trading:pnl
bin/rake day_trading:close_expired
bin/rake day_trading:check_tp_sl
bin/rake day_trading:force_close_all
bin/rake day_trading:manage

curl "http://localhost:3000/sentiment/aggregates?symbol=BTC-USD&limit=5"
```

### Backtesting

```bash
bin/rails "backtest:run[BTC-USD,2026-05-01,2026-07-01,5m]"           # Backtest::Engine, JSON metrics
bin/rails "backtest:walk_forward[BTC-USD,2026-05-01,2026-07-01]"     # Backtest::WalkForward, rolling OOS windows
```

Nightly `CalibrationJob` (02:00 UTC, `CALIBRATE_CRON`) runs the same walk-forward
engine over the live strategy and activates versioned per-symbol `TradingProfile`s.

### Real-Time Signals

```bash
export SIGNAL_EQUITY_USD=1000
export REALTIME_SIGNAL_MIN_CONFIDENCE=65

bin/rake realtime:signals          # full loop
bin/rake realtime:signal_job       # evaluation only (market data already running)
bin/rake realtime:evaluate
bin/rake realtime:evaluate_symbol[BTC-USD]
bin/rake realtime:stats
bin/rake realtime:cleanup
FORCE=true bin/rake realtime:cancel_all
```

**API** (set `SIGNALS_API_KEY`; send `X-API-Key` header or `api_key` query param):

```bash
curl -H "X-API-Key: $SIGNALS_API_KEY" http://localhost:3000/signals/active
curl -H "X-API-Key: $SIGNALS_API_KEY" "http://localhost:3000/signals/high_confidence?threshold=70"
curl -H "X-API-Key: $SIGNALS_API_KEY" "http://localhost:3000/signals/recent?hours=1"
curl -H "X-API-Key: $SIGNALS_API_KEY" http://localhost:3000/signals/stats
curl -X POST -H "X-API-Key: $SIGNALS_API_KEY" http://localhost:3000/signals/evaluate
```

**WebSocket** (Action Cable):

```javascript
const ws = new WebSocket('ws://localhost:3000/cable');
ws.onopen = () => {
  ws.send(JSON.stringify({
    command: 'subscribe',
    identifier: JSON.stringify({ channel: 'SignalsChannel' })
  }));
};
```

**Configuration** (see also `config/initializers/real_time_signals.rb`):

```bash
REALTIME_SIGNAL_EVALUATION_INTERVAL=30
REALTIME_SIGNAL_MIN_CONFIDENCE=60
REALTIME_SIGNAL_MAX_PER_HOUR=10
REALTIME_SIGNAL_DEDUPE_WINDOW=300
SIGNAL_BROADCAST_ENABLED=true
SIGNALS_API_KEY=your_api_key
CANDLE_AGGREGATION_ENABLED=true
```

### TUI Key Bindings

| Key | Action |
|-----|--------|
| `q` / `Q` / `Esc` / `Ctrl+C` | Quit |
| `r` / `R` | Force refresh |
| `p` / `P` | Toggle positions panel |
| `s` / `S` | Toggle signals panel |
| `+` / `=` | Faster refresh (min 1 s) |
| `-` | Slower refresh |

Panels: status bar, open positions (live uPnL), active signals, futures ticks, spot ticks.

### AI Chat Examples

```bash
bin/futuresbot chat

# FuturesBot> show my positions
# FuturesBot> what signals are active?
# FuturesBot> start trading
# FuturesBot> emergency stop
# FuturesBot> BTC price
# FuturesBot> help
```

## Futures Contract Notes

Coinbase monthly futures use product IDs like `BIT-27JUN26-CDE` / `ET-27JUN26-CDE` (symbol + expiry + `-CDE`). Contracts roll — always sync the catalog before trading:

```bash
bin/rake market_data:upsert_futures_products
```

## Production Deployment

```bash
export RAILS_ENV=production
export SECRET_KEY_BASE=your_secret_key
export DATABASE_URL=postgresql://user:pass@host:port/db
export GOOD_JOB_USERNAME=ops
export GOOD_JOB_PASSWORD=your_secure_password

# Coinbase: cdp_api_key.json on the server OR env vars
# Feature flags
export SENTIMENT_ENABLE=true
export SENTIMENT_Z_THRESHOLD=1.5
```

```bash
# Dedicated worker (recommended)
RAILS_ENV=production bundle exec good_job start
```

See [docs/deployment.md](docs/deployment.md).

## Project Status

Feature-rich and heavily tested, but **not a guarantee of profitable live trading**. Track work in [GitHub Issues](https://github.com/Skeyelab/coinbase_futures_bot/issues).

### Codebase snapshot

| Area | Count (approx.) |
|------|-----------------|
| Spec files | 109 |
| RSpec examples | ~2,400 |
| Background jobs | 24 |
| Service files | 61 |
| ActiveRecord models | 14 |

## Contributing

1. Branch from `main`: `git checkout -b feat/description`
2. Write tests; keep StandardRB clean
3. Run `bin/parallel_rspec` (or targeted `bundle exec rspec`) and `bin/standardrb`
4. Open a PR — CI must pass (StandardRB, Brakeman, bundler-audit, tests)

See [docs/development.md](docs/development.md). Do not commit to `main` directly.

## Security & Risk

- Test in paper mode before live capital
- Rotate API keys; keep `cdp_api_key.json` and `.env` out of git
- Use position sizing, stops, and the kill switch (`bin/futuresbot halt`)
- Understand automated trading risks

## Support

- **Docs**: [docs/](docs/)
- **Bugs / features**: [GitHub Issues](https://github.com/Skeyelab/coinbase_futures_bot/issues)
- **Discussions**: GitHub Discussions

## License

Private repository. All rights reserved.
