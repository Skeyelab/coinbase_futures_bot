# CLI Reference

The `bin/futuresbot` command is the primary terminal interface for the Coinbase Futures Bot. It is a [Thor](https://github.com/rails/thor)-based CLI that provides a TUI dashboard, interactive chat, and quick inspection commands — all without opening a browser or writing curl.

## Installation check

```bash
bin/futuresbot version
```

If the command is not found, run `bundle install` from the project root.

---

## Commands

### `dashboard` *(default)*

Launch the full-screen, auto-refreshing TUI dashboard.

```bash
bin/futuresbot dashboard
bin/futuresbot dashboard --refresh 10   # refresh every 10 s
```

| Option | Alias | Default | Description |
|--------|-------|---------|-------------|
| `--refresh N` | `-i N` | `5` | Auto-refresh interval in seconds |

**Key bindings** (no Enter required):

| Key | Action |
|-----|--------|
| `q` / `Q` / `Esc` / `Ctrl-C` | Quit |
| `r` / `R` | Force immediate refresh |
| `p` / `P` | Toggle positions section |
| `s` / `S` | Toggle signals section |
| `+` / `=` | Refresh faster (decrease interval by 1 s, min 1 s) |
| `-` | Refresh slower (increase interval by 1 s) |

The dashboard shows: current UTC time, open day-trading positions, open swing positions, active signal count, GoodJob worker status, and recent signal activity.

Because `dashboard` is the default command, `bin/futuresbot` with no arguments opens the dashboard.

---

### `chat`

Start an interactive AI-powered trading chat session.

```bash
bin/futuresbot chat                              # new session
bin/futuresbot chat --resume                     # resume most-recent session
bin/futuresbot chat --session-id <uuid>          # resume a specific session
```

| Option | Alias | Default | Description |
|--------|-------|---------|-------------|
| `--resume` | `-r` | `false` | Resume the most recent active session |
| `--session-id ID` | `-s ID` | — | Resume a specific session by UUID |

**In-session built-in commands** (no AI call, no network round-trip):

| Command | Description |
|---------|-------------|
| `history [N]` | Show last N chat messages (default: 10) |
| `search <query>` | Full-text search across session history |
| `sessions` | List all active chat sessions |
| `context-status` | Show token count and context window usage |
| `quit` / `exit` / `bye` | End the session |

**Natural-language examples** (sent to the AI):

```
FuturesBot> BTC price
FuturesBot> what signals are active?
FuturesBot> show my positions
FuturesBot> start trading
FuturesBot> stop trading
FuturesBot> position sizing
FuturesBot> analyze BTC market conditions
FuturesBot> what's my current P&L?
FuturesBot> emergency stop
```

---

### `status`

Print a one-line system status summary.

```bash
bin/futuresbot status
```

Example output:

```
📊  FuturesBot Status
────────────────────────────────────────
  Day-trading positions:  2
  Swing positions:        0
  Active signals:         5
  Chat sessions:          1
────────────────────────────────────────
  Status: operational
```

---

### `positions`

List all open trading positions in a formatted table.

```bash
bin/futuresbot positions                    # all open positions (up to 20)
bin/futuresbot positions --type day         # day-trading positions only
bin/futuresbot positions --type swing       # swing positions only
bin/futuresbot positions --limit 5          # show only 5 rows
```

| Option | Alias | Default | Description |
|--------|-------|---------|-------------|
| `--type TYPE` | `-t TYPE` | all | Filter by type: `day` or `swing` |
| `--limit N` | `-n N` | `20` | Maximum rows to display |

---

### `signals`

List recent active trading signals in a formatted table.

```bash
bin/futuresbot signals                           # up to 10 active signals
bin/futuresbot signals --limit 25                # show 25
bin/futuresbot signals --min-confidence 75       # only high-confidence signals
```

| Option | Alias | Default | Description |
|--------|-------|---------|-------------|
| `--limit N` | `-n N` | `10` | Maximum signals to display |
| `--min-confidence N` | `-c N` | `0` | Minimum confidence threshold (0–100) |

---

### `version`

Show version and runtime information.

```bash
bin/futuresbot version
```

---

### `help`

List all commands, or show usage for a specific command.

```bash
bin/futuresbot help
bin/futuresbot help chat
bin/futuresbot help positions
```

---

## Comparison with rake tasks

`bin/futuresbot` is the preferred interactive interface. For batch/scheduled operations use rake tasks:

| Goal | Recommended command |
|------|---------------------|
| Real-time TUI dashboard | `bin/futuresbot dashboard` |
| Interactive chat | `bin/futuresbot chat` |
| Quick position list | `bin/futuresbot positions` |
| Quick signal list | `bin/futuresbot signals` |
| Generate signals (batch) | `bin/rake signals:run` |
| Manage day-trading positions | `bin/rake day_trading:manage` |
| Review PnL | `bin/rake day_trading:pnl` |
| Cancel all active signals | `FORCE=true bin/rake realtime:cancel_all` |

---

**See also:**
- [User Guide](User-Guide) — end-to-end operator workflows
- [Day Trading Guide](Day-Trading-Guide) — full rake task reference
- [API Reference](API-Reference) — REST API endpoints
