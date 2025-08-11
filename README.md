# Coinbase Futures Bot (Rails API + GoodJob)

Rails 8 API-only service for a Coinbase trading bot (futures and spot). Uses PostgreSQL for state and GoodJob for background processing.

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
bin/rake market_data:subscribe[BTC-USD-PERP]
bin/rake market_data:subscribe[BTC-USD-PERP,ETH-USD-PERP]
```
- Spot ticker (BTC-USD):
```bash
bin/rake market_data:subscribe_spot[BTC-USD]
INLINE=1 bin/rake "market_data:subscribe_spot[BTC-USD]"
```

## Paper trading (automated)
- One-off step:
```bash
bin/rake paper:step
```
- Scheduled via GoodJob cron (defaults):
  - PaperTradingJob: every 15 minutes (set `PAPER_CRON` to override)
  - CalibrationJob: daily 02:00 UTC (set `CALIBRATE_CRON` to override)

### Futures (Derivatives) WebSocket
- Requires a futures WS URL via env:
```bash
export COINBASE_FUTURES_WS_URL=wss://<futures-ws-endpoint>
```
- Run inline (foreground):
```bash
INLINE=1 bin/rake "market_data:subscribe_futures[BTC-USD-PERP]"
```
Note: Endpoint and schema may differ from Advanced Trade; handler logs raw fields if schema is unknown.

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
