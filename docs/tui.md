# TUI Dashboard — Primary Interface

The FuturesBot ships with a full-screen, auto-refreshing **Terminal User Interface (TUI)** as its primary operator interface.  Launch it with a single command; no browser or web server required for day-to-day operation.

```bash
bin/futuresbot
```

## Why the TUI?

| Concern | TUI | Web / REST |
|---------|-----|-----------|
| **Startup time** | Instant (direct DB connection) | Requires `bin/rails server` |
| **Resource usage** | Low (single Ruby process) | Full Rails stack |
| **Dependency on network** | None (reads local DB) | HTTP server must be running |
| **Real-time feel** | Auto-refreshing, live PnL | Manual `curl` / page reload |
| **Interactive control** | Single-keypress actions | Form submissions / API calls |

## Launching the Dashboard

```bash
# Default launch (5 s auto-refresh)
bin/futuresbot

# Custom refresh interval (seconds)
bin/futuresbot dashboard --refresh 10

# Show help for all available commands
bin/futuresbot help
```

## Key Bindings

No Enter key required — all bindings are single-character:

| Key | Action |
|-----|--------|
| `q` / `Q` / `Esc` / `Ctrl+C` | Quit the dashboard |
| `r` / `R` | Force an immediate data refresh |
| `p` / `P` | Toggle the Open Positions panel |
| `s` / `S` | Toggle the Active Signals panel |
| `+` / `=` | Speed up auto-refresh (−1 s, minimum 1 s) |
| `-` | Slow down auto-refresh (+1 s) |

## Dashboard Panels

### Header

Displays the bot name, last-refresh timestamp, and the key-binding reference.

### Status Bar

```
Status  ·  Day: 2  ·  Swing: 1  ·  Signals: 4  ·  Sessions: 1  ·  Coinbase: LIVE (3s ago)
```

- **Day / Swing** — count of open day-trading and swing positions
- **Signals** — count of currently active signal alerts
- **Sessions** — count of active chat sessions
- **Coinbase** — `LIVE` (tick ≤ 15 s old), `STALE` (older), or `NO DATA`

### Open Positions

Toggled with `p`.  Shows up to 15 most-recently opened positions:

| Column | Description |
|--------|-------------|
| ID | Database ID |
| Product | Futures or spot product ID (e.g. `BIT-29AUG25-CDE`) |
| Side | `LONG` (green) or `SHORT` (red) |
| Entry | Entry price |
| Size | Position size |
| Type | `Day` or `Swing` |
| U.PnL | Live unrealized PnL calculated from the latest market tick |

### Active Signals

Toggled with `s`.  Shows up to 10 most-recent active signals:

| Column | Description |
|--------|-------------|
| ID | Database ID |
| Symbol | Instrument (e.g. `BTC-USD`) |
| Side | `LONG` (green) or `SHORT` (red) |
| Type | Signal type (e.g. `EMA_CROSS`) |
| Conf% | Confidence score — ≥ 80 green, ≥ 60 yellow, < 60 red |
| Strategy | Strategy name |

### Live Prices

Two sub-panels, automatically separated:

- **Futures Live Prices** — products matching the pattern `SYMBOL-DDMMMYY-CDE`
- **Spot Prices** — all other products (e.g. `BTC-USD`)

Each row shows the product ID, last price, and how many seconds ago the tick was received.  Ticks ≤ 15 s old are highlighted green; older ticks are yellow.

### Footer

Displays the last-refresh time, seconds until next refresh, and the current interval.

## Other CLI Commands

All commands share the same `bin/futuresbot` entry point:

```bash
# One-shot status summary (non-interactive)
bin/futuresbot status

# List open positions (non-interactive, filterable)
bin/futuresbot positions
bin/futuresbot positions --type day
bin/futuresbot positions --type swing
bin/futuresbot positions --limit 5

# List active signals (non-interactive, filterable)
bin/futuresbot signals
bin/futuresbot signals --limit 20
bin/futuresbot signals --min_confidence 75

# AI-powered interactive chat
bin/futuresbot chat
bin/futuresbot chat --resume
bin/futuresbot chat --session_id <uuid>

# Show version info
bin/futuresbot version

# Show help
bin/futuresbot help
```

## Terminal Compatibility

The dashboard uses standard ANSI/VT100 escape codes and the alternate screen
buffer (`\e[?1049h`) so it never clutters your shell scrollback.  It works in:

- macOS Terminal, iTerm2
- Linux terminals (GNOME Terminal, Konsole, Alacritty, kitty, …)
- Any terminal that supports 256-colour ANSI (virtually all modern terminals)

For non-TTY environments (pipes, CI, tests) the dashboard automatically falls
back to a single one-shot render with no interactive loop.

## Architecture

```
bin/futuresbot
  └── Cli::FuturesBotCli  (lib/cli/futures_bot_cli.rb)
        ├── dashboard  →  Cli::TuiDashboard#start  (lib/cli/tui_dashboard.rb)
        ├── chat       →  inline loop + ChatBotService
        ├── status     →  inline ActiveRecord queries
        ├── positions  →  inline ActiveRecord queries
        └── signals    →  inline ActiveRecord queries
```

`TuiDashboard` connects directly to the Rails application database (PostgreSQL)
and renders everything in a single mutable string buffer using ANSI escape codes
— no gems beyond the Ruby standard library are required.

## Running Tests

```bash
# TUI unit tests
bundle exec rspec spec/lib/cli/tui_dashboard_spec.rb

# CLI integration tests
bundle exec rspec spec/lib/cli/futures_bot_cli_spec.rb
```
