# User Guide

This guide covers the current operator-facing surfaces in the repo: terminal CLI, chat, HTTP APIs, the positions web UI, and the main rake entrypoints.

## Accessing the Bot

| Surface | Use it for | Command / URL |
|---|---|---|
| `bin/futuresbot` | TUI dashboard and quick inspection | `bin/futuresbot` |
| `bin/futuresbot chat` | conversational operator workflow | `bin/futuresbot chat` |
| Signals API | signal inspection and manual evaluation | `/signals/*` |
| Positions API | position listings and exposure summaries | `/api/positions/*` |
| Positions UI | server-rendered position management | `/positions` |
| Rake tasks | one-shot operational actions | `bin/rake ...` |

## Before You Start

For local use, start the app and worker first:

```bash
bin/rails server
bundle exec good_job start
```

Optional real-time loop:

```bash
bin/rake realtime:signals
```

Health checks:

```bash
curl http://localhost:3000/up
curl http://localhost:3000/health
```

Notes:
- `bin/futuresbot dashboard` and `bin/futuresbot chat` sync positions from Coinbase on startup unless `FUTURESBOT_SKIP_POSITION_SYNC=1`.
- Most `/signals/*` endpoints require `SIGNALS_API_KEY` via `X-API-Key` header or `api_key` query param.

## Analyze the Market

### Chat

```bash
bin/futuresbot chat
```

Examples:

```text
BTC price
show recent trading alerts
what signals are active?
analyze BTC market conditions
show my positions
```

Local chat commands that do not invoke the AI:

```text
history 10
search btc
sessions
context-status
quit
```

### Signals API

```bash
curl -H "X-API-Key: $SIGNALS_API_KEY" http://localhost:3000/signals/active
curl -H "X-API-Key: $SIGNALS_API_KEY" "http://localhost:3000/signals/high_confidence?threshold=80"
curl -H "X-API-Key: $SIGNALS_API_KEY" "http://localhost:3000/signals/recent?hours=1"
curl -H "X-API-Key: $SIGNALS_API_KEY" "http://localhost:3000/signals/stats?hours=24"
curl -H "X-API-Key: $SIGNALS_API_KEY" "http://localhost:3000/signals?symbol=BIT-27JUN26-CDE&min_confidence=70"
```

Sentiment aggregates:

```bash
curl "http://localhost:3000/sentiment/aggregates?symbol=BTC-USD&window=15m"
```

### Manual Signal Evaluation

Evaluate all enabled pairs:

```bash
curl -X POST -H "X-API-Key: $SIGNALS_API_KEY" http://localhost:3000/signals/evaluate
bin/rake realtime:evaluate
```

Evaluate one symbol / product id:

```bash
curl -X POST -H "X-API-Key: $SIGNALS_API_KEY" \
  "http://localhost:3000/signals/evaluate?symbol=BIT-27JUN26-CDE"

bin/rake "realtime:evaluate_symbol[BIT-27JUN26-CDE]"
```

### Market Data Tasks

```bash
bin/rails "market_data:backfill[2]"                      # all timeframes, all enabled contracts
bin/rails "market_data:backfill[30,'BTC-USD ETH-USD']"   # deep backfill for specific products
bin/rake "market_data:subscribe[BTC-USD]"
PRODUCT_IDS=BTC-USD,ETH-USD bin/rake market_data:subscribe
```

## Trading Controls

### Kill Switch

```bash
bin/futuresbot halt --reason "manual stop"
bin/futuresbot halt_status
bin/futuresbot resume
```

### Signal Loop

```bash
bin/rake realtime:signals
bin/rake realtime:signal_job
bin/rake realtime:stats
FORCE=true bin/rake realtime:cancel_all
```

### Paper / Live Safety

- Use paper-trading configuration until you trust strategy behavior.
- Treat `.env.example` as shape only, not real credentials.
- Live trading today centers on expiring dated futures contracts (BIT/ET); perpetuals are the adopted primary venue per ADR 0002 but not yet live. Use real contract/product ids where required.

## Watch Positions

### CLI

```bash
bin/futuresbot status
bin/futuresbot positions
bin/futuresbot positions --type day
bin/futuresbot positions --type swing
bin/futuresbot signals --min-confidence 75
```

### Web UI

Open:

```text
http://localhost:3000/positions
```

The positions UI uses HTTP Basic auth via `POSITIONS_UI_USERNAME` and `POSITIONS_UI_PASSWORD`.

### Positions API

```bash
curl http://localhost:3000/api/positions
curl "http://localhost:3000/api/positions?type=day_trading"
curl "http://localhost:3000/api/positions?type=swing_trading"
curl http://localhost:3000/api/positions/summary
curl http://localhost:3000/api/positions/exposure
```

## Day-Trading Operations

Common tasks:

```bash
bin/rake day_trading:check_positions
bin/rake day_trading:pnl
bin/rake day_trading:details
bin/rake day_trading:manage
```

See [Day-Trading-Guide](Day-Trading-Guide) for the full task list.

## Monitoring and Incident Response

Start here during incidents:

```bash
curl http://localhost:3000/health
curl http://localhost:3000/signals/health
bin/futuresbot halt_status
bin/rake realtime:stats
```

See [Monitoring](Monitoring) for the full operational checklist.
