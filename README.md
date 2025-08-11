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

## Backtesting
- CSV replay for spot-driven strategy.
- Expected CSV headers: `time,price` (optional `product_id`). Example:

```csv
time,price
2024-01-01T00:00:00Z,45000.12
2024-01-01T00:00:01Z,45000.30
```

- Run backtest:
```bash
bin/rake market_data:backtest_spot_csv[/absolute/path/to/btc_usd_ticks.csv,BTC-USD,BTC-USD-PERP]
# Or with env vars
CSV_PATH=/absolute/path/to/btc_usd_ticks.csv SPOT_PRODUCT=BTC-USD FUTURES_PRODUCT=BTC-USD-PERP bin/rake market_data:backtest_spot_csv
```

- Output prints execution decisions; no orders are placed.

### DB-backed backtesting
- Persist live ticks:
```bash
INLINE=1 bin/rake "market_data:ingest_spot_to_db[BTC-USD]"
```

- Backtest over an interval:
```bash
bin/rake market_data:backtest_spot_db[2025-08-11T00:00:00Z,2025-08-11T01:00:00Z,BTC-USD,BTC-USD-PERP]
# Or with env vars
START_ISO=2025-08-11T00:00:00Z END_ISO=2025-08-11T01:00:00Z bin/rake market_data:backtest_spot_db
```

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
