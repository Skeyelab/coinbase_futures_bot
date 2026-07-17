---
name: futuresbot
description: >-
  Drive and query the running Coinbase futures bot from a second terminal.
  Use when the operator asks "how's the bot doing?", wants to check
  positions / signals / PnL / halt state / data freshness, or wants to
  "control the bot", "halt trading", "resume trading", or "/futuresbot".
  Reads live state via the bot's JSON CLI and executes control actions
  through documented commands only — never by placing free-form orders.
---

# /futuresbot — operator copilot for the running bot

The operator runs the bot in one terminal (`bin/futuresbot start`) and uses you
in a second terminal as a copilot against the **shared database**. You read live
state and issue control actions through the `bin/futuresbot` CLI only.

## Golden rules

1. **Read structured, never scrape.** Every read/status command supports
   `--json`. Always pass `--json` and parse the document — never parse the
   human-formatted ANSI tables.
2. **Only documented CLI commands.** Never place or modify orders by any
   free-form means. The only control commands are `halt`, `resume`, and (with
   confirmation) `close`. There is no "buy"/"sell" command and you must not
   invent one.
3. **Confirm before touching money.** Halting/resuming *signal generation* may
   proceed when the operator asked for it in the same message. **Closing a
   position, or any action that moves real money, requires explicit operator
   confirmation first** — state exactly what you will run and wait for a "yes".
   If dry-run is active (`dry_run.active == true`) orders are simulated, but
   still confirm — the operator may not realize which mode they are in.
4. **Verify after every write.** After `halt`/`resume`, re-read
   `halt_status --json` and report the new state.
5. **Flag stale data.** If `eval.age_seconds` is large (say > 120s) or
   sentiment/tick data is old, say so — the bot may not be evaluating.

## Reading state

```bash
bin/futuresbot status --json        # halt, dry_run, position counts, signals, eval age, paper account
bin/futuresbot positions --json     # open positions: product_id, side, entry_price, size, tp/sl, unrealized_pnl, paper
bin/futuresbot signals --json       # active signals: symbol, side, confidence, strategy, timestamp
bin/futuresbot halt_status --json   # active / halted / reason / as_of
```

All JSON documents use snake_case keys, ISO-8601 UTC timestamps, and an `as_of`
field. `FUTURESBOT_JSON=1` also forces JSON without the flag. Exit code is 0 on
success, non-zero on failure — branch on it.

To answer "how's the bot doing?": read `status --json` (and `positions --json`
if they ask about PnL), then synthesize — halt state, open positions and total
unrealized PnL, active signal count, eval freshness, and whether dry-run is on.

## Control actions

**Halt (kill switch) — no money moved, ok to run when asked:**
```bash
bin/futuresbot halt --json --reason "CPI print in 10 min"
bin/futuresbot halt_status --json      # verify halted == true
```

**Resume:**
```bash
bin/futuresbot resume --json
bin/futuresbot halt_status --json      # verify active == true
```

**Close a position — MONEY-TOUCHING, confirm first:**
1. Read `positions --json`, identify the position id.
2. Tell the operator exactly what you will run and wait for explicit confirmation.
3. Only after "yes":
   ```bash
   bin/futuresbot close   # interactive; prompts for the OPEN position id
   ```
4. Re-read `positions --json` and confirm it closed.

## Dry-run

- `bin/futuresbot dry_run_status --json`-style state is in `status --json` under
  `dry_run`. When `dry_run.active` is true, orders are simulated against the
  paper account (`status.paper`), nothing reaches Coinbase.
- Enable/disable: `bin/futuresbot dry_run_on` / `dry_run_off`. Treat enabling
  dry-run as safe; treat `dry_run_off` (returning to LIVE) as a money-mode
  change — confirm first.

## Two-terminal workflow

- Terminal 1: `bin/futuresbot start` (bot + market data + signal + sentiment).
- Terminal 2: Claude Code — you run the `--json` commands above.
- Control writes propagate cross-process via the durable `bot_runtime_stats`
  store (halt and dry-run state are shared), so a `halt` you run here takes
  effect in the running bot.

## Example session

> Operator: "how's the bot doing?"

```bash
bin/futuresbot status --json
```
→ Synthesize: "Trading is ACTIVE (not halted), 1 open NOL position, eval ran 18s
ago (fresh), 2 active signals, dry-run off." Add unrealized PnL from
`positions --json` if asked.

> Operator: "halt trading, CPI print in 10 minutes"

```bash
bin/futuresbot halt --json --reason "CPI print in 10 min"
bin/futuresbot halt_status --json
```
→ "Halted. Verified: halted, reason 'CPI print in 10 min'."

> Operator: "close the NOL position"

→ "That closes a live position (moves money). I'll run `bin/futuresbot close`
for position 42 (NOL-19JUN26-CDE, SHORT 1). Confirm?" — wait for yes.
