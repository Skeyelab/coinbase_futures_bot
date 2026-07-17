# CLI Reference

`bin/futuresbot` is the repo's terminal-first operator interface.

## Quick Check

```bash
bin/futuresbot help
bin/futuresbot version
```

## Commands

### `dashboard`

Launch the real-time TUI dashboard. This is the default command when no subcommand is given.

```bash
bin/futuresbot
bin/futuresbot dashboard
bin/futuresbot dashboard --refresh 10
```

Options:
- `--refresh`, `-r`, `-i`: refresh interval in seconds

Layout:
- **Header** — app name and clock.
- **System strip** (always visible, on every tab): halt status (`✓ ACTIVE` / `⛔ TRADING HALTED`), position and signal counts, `Eval: Ns ago` (durable timestamp — accurate even in development), and a sentiment one-liner (`OIL-USD z=-0.4 (3/15m)`) that dims with `⚠ … (stale)` when the pipeline is idle.
- **Tabs** — switch with number keys:
  - `1` Overview — condensed top-3 positions, signals, and prices.
  - `2` Positions — framed table; empty state prompts `press [i] to sync from Coinbase`.
  - `3` Signals — framed table; empty state notes evaluation must be running.
  - `4` Market — futures and spot as separate framed panels with per-tick freshness.
  - `5` Health/Ops — eval recency, sentiment per enabled symbol, source health, enabled-contract count, market-data tick freshness, and the operations menu.

Action keys:
- `q`, `Q`, `Esc`, `Ctrl-C`: quit
- `r`, `R`: force refresh
- `i`, `I`: import/sync positions from Coinbase (also auto-reconciles ghost OPEN rows)
- `c`, `C`: close an open position
- `o`, `O`: manual reconcile (import already auto-reconciles)
- `t` / `s`: edit take-profit / stop-loss
- `h`, `H`: toggle trading halt state
- `m`: toggle realtime monitoring
- `?`, `/`: operation picker menu

Notes:
- `dashboard` syncs positions on startup unless `FUTURESBOT_SKIP_POSITION_SYNC=1`.
- The dashboard reads local DB state and recent market data; it does not replace the API.
- Sentiment collection does **not** run in `dashboard`; use `bin/futuresbot start` (or GoodJob cron in a deployed app) to keep the pipeline fed.

### `chat`

Start an interactive chat session.

```bash
bin/futuresbot chat
bin/futuresbot chat --resume
bin/futuresbot chat --session-id <uuid>
```

Options:
- `--resume`, `-r`: resume most recent active session
- `--session-id`, `-s`: resume a specific session

Local chat commands:

```text
history 10
search btc
sessions
context-status
quit
```

### `status`

Show a short system summary.

```bash
bin/futuresbot status
```

Includes a **Sentiment** section: per enabled-contract symbol z-score/count/window
(e.g. `OIL-USD: z=-0.4 (3/15m)`), the last-event age, and a stale/missing warning.
Use it to verify the sentiment pipeline is collecting without launching the full TUI —
`No sentiment data yet` or `⚠ STALE` means there are no recent events. Enable futures
products first with `bin/rake market_data:upsert_futures_products` so enabled contracts
resolve to sentiment symbols (NOL/OIL → `OIL-USD`).

### `positions`

List open positions.

```bash
bin/futuresbot positions
bin/futuresbot positions --type day
bin/futuresbot positions --type swing
bin/futuresbot positions --limit 5
```

Options:
- `--type`, `-t`: `day` or `swing`
- `--limit`, `-n`: max rows

### `signals`

List recent active signals.

```bash
bin/futuresbot signals
bin/futuresbot signals --limit 25
bin/futuresbot signals --min-confidence 75
```

Options:
- `--limit`, `-n`: max rows
- `--min-confidence`, `-c`: minimum confidence threshold

### `halt`

Trigger the trading kill switch.

```bash
bin/futuresbot halt
bin/futuresbot halt --reason "manual stop"
```

### `resume`

Resume trading after a halt.

```bash
bin/futuresbot resume
```

### `halt_status`

Show current kill-switch state.

```bash
bin/futuresbot halt_status
```

### `version`

Show runtime version info.

```bash
bin/futuresbot version
```

### `help`

```bash
bin/futuresbot help
bin/futuresbot help dashboard
```

### `tree`

Show the command tree.

```bash
bin/futuresbot tree
```

## Related Rake Tasks

Use rake for one-shot or scheduled operational flows:

```bash
bin/rake realtime:signals
bin/rake realtime:evaluate
bin/rake "realtime:evaluate_symbol[BIT-27JUN26-CDE]"
bin/rake realtime:stats
bin/rake day_trading:manage
bin/rake day_trading:pnl
```

## Startup Behavior

- `dashboard` and `chat` perform startup position sync unless `FUTURESBOT_SKIP_POSITION_SYNC=1`.
- The CLI works best with the Rails app and GoodJob worker already running.

## See Also

- [User Guide](User-Guide)
- [Day-Trading-Guide](Day-Trading-Guide)
- [Monitoring](Monitoring)
