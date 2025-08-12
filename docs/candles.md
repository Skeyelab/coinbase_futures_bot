# Candle Data Collection

This service collects and stores OHLCV candles primarily for Coinbase spot markets (e.g., `BTC-USD`). Candles are stored in the `candles` table and used by strategies and paper trading.

## What is collected
- **Timeframes**: `1h` and `15m`
  - `1h` candles come directly from the API with granularity 3600s.
  - `15m` candles are fetched with granularity 900s. The code path is named `upsert_30m_candles` for historical reasons but stores as `15m`.
- **Fields**: `symbol`, `timeframe`, `timestamp`, `open`, `high`, `low`, `close`, `volume`.
- **Uniqueness**: Unique on `(symbol, timeframe, timestamp)` to prevent duplicates.

## Storage schema
```
symbol: string (e.g., BTC-USD)
timeframe: string (15m, 1h, 6h, 1d)
timestamp: datetime UTC
open/high/low/close: decimal(20,10)
volume: decimal(30,10)
```

## How candles are fetched
- Implemented in `MarketData::CoinbaseRest`:
  - `fetch_candles(product_id:, start_iso8601:, end_iso8601:, granularity:)` returns arrays of `[time, low, high, open, close, volume]`.
  - `upsert_1h_candles(product_id:, start_time:, end_time:)` writes `1h` candles.
  - `upsert_1h_candles_chunked(...)` collects large ranges in chunks (avoids rate limits).
  - `upsert_30m_candles(product_id:, ...)` writes `15m` candles using 900s granularity.
  - `upsert_30m_candles_chunked(...)` chunked version for large ranges.

- Scheduled fetching is handled by `FetchCandlesJob` (GoodJob cron):
  - Calculates a `start_time` as the later of:
    - last stored candle timestamp + 1 hour
    - `backfill_days` ago (defaults to 7)
  - Upserts `1h` candles for `BTC-USD`.

## Running it
- One-off backfill via Rake:
  - `bin/rake market_data:backfill_candles[7]` enqueues `FetchCandlesJob` with 7 days backfill.
  - `bin/rake market_data:backfill_1h_candles[30]` directly fetches and stores `1h` candles for the last 30 days.
  - `bin/rake market_data:backfill_30m_candles[7]` fetches and stores `15m` candles for the last 7 days.
  - `bin/rake market_data:test_1h_candles[1]` quick test for `1h` fetching.
  - `bin/rake market_data:test_granularities` prints supported granularities.

- Scheduled via GoodJob cron (see `config/initializers/good_job.rb`):
  - `FetchCandlesJob` runs at minute 5 of every hour by default.
  - Configure with `CANDLES_CRON` env var (cron syntax), e.g.: `CANDLES_CRON="*/30 * * * *"`.

## Environment variables
- `COINBASE_REST_URL` (optional): Override API base URL; default `https://api.exchange.coinbase.com`.
- `COINBASE_API_KEY`, `COINBASE_API_SECRET` (optional): If set, authenticated calls may have better limits.
- `CANDLES_CRON` (optional): GoodJob cron schedule for `FetchCandlesJob`.

## Notes and tips
- The API may return data newest-first. The importer sorts oldest→newest before upserting.
- Large backfills use chunked fetching to reduce rate-limit errors.
- If you only want to catch up to the latest candle without re-fetching history, prefer `market_data:backfill_candles[<small_number>]` or rely on the hourly cron.
- `Candle` model scopes:
  - `Candle.for_symbol("BTC-USD")`
  - `Candle.hourly` and `Candle.fifteen_minute`

## Troubleshooting
- If you see rate-limit errors, lower `chunk_days` (see `upsert_1h_candles_chunked`) or add API credentials.
- Ensure `TradingPair` exists for `BTC-USD`: run `bin/rake market_data:upsert_futures_products` first if needed.
- Check GoodJob dashboard to confirm `FetchCandlesJob` runs on schedule.