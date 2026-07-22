# Candle Data Collection

This service collects and stores OHLCV candles for every enabled contract (e.g., `BTC-USD`, `ETH-USD`, nano futures). Candles are stored in the `candles` table and used by strategies, the backtest engine, and nightly calibration.

## What is collected
- **Timeframes**: `1m`, `5m`, `15m`, `30m`, `1h`, and `1d` for all enabled contracts.
- **Fields**: `symbol`, `timeframe`, `timestamp`, `open`, `high`, `low`, `close`, `volume`.
- **Uniqueness**: Unique on `(symbol, timeframe, timestamp)` to prevent duplicates.

## Storage schema
```
symbol: string (e.g., BTC-USD)
timeframe: string (1m, 5m, 15m, 30m, 1h, 1d)
timestamp: datetime UTC
open/high/low/close: decimal(20,10)
volume: decimal(30,10)
```

## How candles are fetched
- Implemented in `MarketData::CoinbaseRest`:
  - `fetch_candles(product_id:, start_iso8601:, end_iso8601:, granularity:)` returns arrays of `[time, low, high, open, close, volume]`.
  - `upsert_<tf>_candles(product_id:, start_time:, end_time:)` writes candles for a timeframe.
  - `upsert_1m_candles_chunked`, `upsert_5m_candles_chunked`, `upsert_15m_candles_chunked`, and `upsert_1h_candles_chunked` fetch large ranges in chunks (the API truncates responses over ~300-350 candles).

- Scheduled fetching is handled by `FetchCandlesJob` (GoodJob cron, hourly):
  - Runs for **all enabled contracts**, and auto-disables contracts whose `expiration_date` has passed. Suspension (`Trading::SymbolSuspension`) does not affect this: suspended symbols keep collecting candles — that is how new venue candidates (perps per ADR 0002) accumulate the history their walk-forward calibration needs.
  - Normally incremental: starts just after the newest stored candle. When stored history is **shallower** than the requested `backfill_days` window, it refetches the whole window (backward fill) — upserts make the overlap idempotent, and once the deep window exists subsequent runs are incremental again.
  - Chunk sizes: 1m at 5 hours, 5m at 24 hours, 15m at 3 days, 1h at 14 days. 30m is capped at 7 days per run; 1d is a single request.
  - 1m history is capped at `MAX_1M_BACKFILL_DAYS` (default 3) unless a deeper value is passed explicitly — deep 1m backfill is API-expensive and nothing needs it by default.

## Running it
- One-off backfill via Rake:
  - `bin/rails "market_data:backfill[60]"` — inline deep backfill, 60 days, all enabled contracts.
  - `bin/rails "market_data:backfill[60,'BTC-USD ETH-USD']"` — restrict to specific products.
  - `bin/rails "market_data:backfill[60,'BTC-USD',30]"` — third arg raises the 1m cap (here 30 days of 1m).
  - `bin/rake market_data:backfill_candles[7]` enqueues `FetchCandlesJob` in the background with 7 days backfill.
  - `bin/rake market_data:test_granularities` prints supported granularities.

- Scheduled via GoodJob cron (see `config/initializers/good_job.rb`):
  - `FetchCandlesJob` runs at minute 5 of every hour by default.
  - Configure with `CANDLES_CRON` env var (cron syntax), e.g.: `CANDLES_CRON="*/30 * * * *"`.

## Environment variables
- `COINBASE_REST_URL` (optional): Override API base URL; default `https://api.exchange.coinbase.com`.
- `COINBASE_API_KEY`, `COINBASE_API_SECRET` (optional): If set, authenticated calls may have better limits.
- `CANDLES_CRON` (optional): GoodJob cron schedule for `FetchCandlesJob`.
- `MAX_1M_BACKFILL_DAYS` (optional): Cap on 1m backfill depth (default 3 days).

## Notes and tips
- The API may return data newest-first. The importer sorts oldest→newest before upserting.
- Large backfills use chunked fetching to reduce rate-limit errors.
- Higher-frequency timeframes use shorter chunk sizes to respect API response limits.
- If you only want to catch up to the latest candle without re-fetching history, rely on the hourly cron or a small `backfill_days`.
- `Candle` model scopes:
  - `Candle.for_symbol("BTC-USD")`
  - `Candle.one_minute`, `Candle.five_minute`, `Candle.fifteen_minute`, `Candle.hourly`

## Troubleshooting
- If you see rate-limit errors, lower the chunk sizes (see chunked methods) or add API credentials.
- Ensure enabled `Contract` records exist: run `bin/rake market_data:upsert_futures_products` first if needed.
- Check the GoodJob dashboard to confirm `FetchCandlesJob` runs on schedule.
