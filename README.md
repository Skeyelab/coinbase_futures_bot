# Coinbase Futures Bot (Rails API + GoodJob)

Rails 8 API-only service for a Coinbase futures trading bot. Uses PostgreSQL for state and GoodJob for background processing.

## Prerequisites
- Ruby 3.2.x (RVM recommended; repo uses `.ruby-version`)
- PostgreSQL (DATABASE_URL)
- Bundler

## Setup
```bash
rvm use ruby-3.2.2@coinbase_futures_bot --create
bundle install
bin/rails db:prepare
```

## Run (development)
```bash
bin/rails s
# GoodJob runs async in-process by default
```

## Market data subscriber
- Enqueue ticker subscription (GoodJob):
```bash
bin/rake "market_data:subscribe[BTC-USD-PERP]"
bin/rake "market_data:subscribe[BTC-USD-PERP,ETH-USD-PERP]"
# or use env var (no quoting needed):
PRODUCT_IDS=BTC-USD-PERP bin/rake market_data:subscribe
```

Logs will show ticker messages at debug level.

## Admin UI
- GoodJob dashboard (development): http://localhost:3000/good_job

## Production notes
- Run a dedicated worker instead of in-process:
```bash
bundle exec good_job start
```
- Consider mounting `/good_job` behind auth if exposed.

## Contributing workflow
- All substantive changes go through PRs. CI (RuboCop, Brakeman) must pass.
- Update `SESSION_NOTES.md` for notable changes.
