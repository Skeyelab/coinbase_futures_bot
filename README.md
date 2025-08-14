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

## Tests (RSpec)
- Run the full suite:
```bash
bundle exec rspec
```
- Run a specific spec or directory:
```bash
bundle exec rspec spec/models/candle_spec.rb
```
- CI runs `bundle exec rspec` with PostgreSQL via GitHub Actions (see `.github/workflows/test.yml`).

## Market data subscriber
- Enqueue ticker subscription (GoodJob):
```bash
bin/rake market_data:subscribe[BTC-USD-PERP]
PRODUCT_IDS=BTC-USD-PERP,ETH-USD-PERP bin/rake market_data:subscribe
```
- Spot ticker:
```bash
bin/rake market_data:subscribe_spot[BTC-USD]
PRODUCT_IDS=BTC-USD,ETH-USD bin/rake market_data:subscribe_spot
INLINE=1 PRODUCT_IDS=BTC-USD bin/rake "market_data:subscribe_spot[BTC-USD]"
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

## Sentiment
- Sources: CryptoPanic news aggregator (MVP). Reddit/Twitter can be added later.
- Storage:
  - `sentiment_events`: raw normalized items with optional `score`/`confidence`.
  - `sentiment_aggregates`: rolling aggregates per symbol/window (`5m`,`15m`,`1h`) including `z_score`.
- Scoring: lightweight lexicon scorer (dependency-free) used by `ScoreSentimentJob`. Can be replaced by FinBERT later.
- Jobs and schedules (GoodJob cron defaults):
  - `FetchCryptopanicJob`: every 2 minutes (`SENTIMENT_FETCH_CRON`)
  - `ScoreSentimentJob`: every 2 minutes (`SENTIMENT_SCORE_CRON`)
  - `AggregateSentimentJob`: every 5 minutes (`SENTIMENT_AGG_CRON`)
- Feature flags:
  - `SENTIMENT_ENABLE`: when `true`, gates entries in `Strategy::MultiTimeframeSignal` using 15m z-score
  - `SENTIMENT_Z_THRESHOLD`: default `1.2`; entries require `|z| >= threshold` and sign aligned (z>0 for longs, z<0 for shorts)
- Environment:
  - `CRYPTOPANIC_TOKEN` (required to fetch real data)
- Endpoint:
  - `GET /sentiment/aggregates?symbol=BTC-USD-PERP&window=15m&limit=20`
    - Returns latest aggregates as JSON for quick inspection/monitoring.

### Enable sentiment in production
1) Migrate DB
```bash
RAILS_ENV=production bin/rails db:migrate
```
2) Set environment variables
```bash
export CRYPTOPANIC_TOKEN=...   # required for news fetch
export SENTIMENT_ENABLE=true    # enable gating in strategies
export SENTIMENT_Z_THRESHOLD=1.2
# Optional: tune schedules
export SENTIMENT_FETCH_CRON="*/2 * * * *"
export SENTIMENT_SCORE_CRON="*/2 * * * *"
export SENTIMENT_AGG_CRON="*/5 * * * *"
```
3) Run workers (GoodJob)
- In-process (Rails server): default `async` works for small loads.
- Dedicated worker (recommended):
```bash
RAILS_ENV=production bundle exec good_job start
```
4) Network egress
- Allow HTTPS egress to `cryptopanic.com`.

5) Verify
```bash
curl -s "https://<host>/sentiment/aggregates?symbol=BTC-USD-PERP&window=15m&limit=5" | jq
```

Note: The `/sentiment/aggregates` endpoint is read-only and unauthenticated by default. Restrict via network or add auth if exposed publicly.

## Production notes
- Run a dedicated worker instead of in-process:
```bash
bundle exec good_job start
```
- Consider mounting `/good_job` behind auth if exposed.

## Contributing workflow
- All substantive changes go through PRs. CI (RuboCop, Brakeman, RSpec) must pass.
- Update `SESSION_NOTES.md` for notable changes.

## Candle data collection
- Fetch and store OHLCV candles (Coinbase spot):
  - `bin/rake market_data:backfill_candles[7]` enqueues `FetchCandlesJob` (default 7 days).
  - `bin/rake market_data:backfill_1h_candles[30]` writes `1h` candles for last 30 days.
  - `bin/rake market_data:backfill_30m_candles[7]` writes `15m` candles for last 7 days.
  - `bin/rake market_data:test_1h_candles[1]` quick test.
  - `bin/rake market_data:test_granularities` prints supported granularities.
- Scheduled via GoodJob cron at minute 5 each hour by default. Override with `CANDLES_CRON`.
- See `docs/candles.md` for full details (schema, env vars, chunked fetching, troubleshooting).
