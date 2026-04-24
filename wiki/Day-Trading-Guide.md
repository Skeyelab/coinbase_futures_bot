# Day Trading Guide

## Overview

The Coinbase Futures Bot is optimised for **intraday (day) trading** — short-term positions that are opened and closed within the same trading day. This guide explains how the day-trading system works and how to operate it safely.

## What Is Day Trading Mode?

In day trading mode the bot:

- Targets **1–8 hour hold times** with same-day closure
- Uses **tighter stop losses** (20–40 bps) for faster risk management
- **Automatically closes** all open positions at midnight UTC and when the 24-hour limit is reached
- Monitors **take profit / stop loss** levels every 15 minutes in the background

## Quick Start

```bash
# 1. Enable day trading mode
export DEFAULT_DAY_TRADING=true

# 2. Set your capital and risk parameters
export SIGNAL_EQUITY_USD=5000
export RISK_PER_TRADE_PERCENT=2
export REALTIME_SIGNAL_MIN_CONFIDENCE=65

# 3. Start the real-time system
SIGNAL_EQUITY_USD=5000 bin/rake realtime:signals

# 4. Monitor positions in another terminal
bin/rake day_trading:check_positions
```

## Position Lifecycle

```
Signal Generated
      │
      ▼
Position Opened
      │
      ▼
Active Trading ──→ TP/SL Monitoring (every 15 min)
      │                      │
      │            Hit TP or SL?
      │                 │  Yes → Close Position
      │                 │
      ▼
Approaching 24-Hour Limit (23.5 h warning)
      │
      ▼
Automatic Closure at 24 Hours
      │
      ▼
Position Closed → Retained for 30 days
```

## Rake Tasks

### Monitoring

```bash
# Show all open day trading positions and their status
bin/rake day_trading:check_positions

# Show current unrealised PnL for all open positions
bin/rake day_trading:pnl

# Show detailed position breakdown (entry, TP, SL, age)
bin/rake day_trading:details
```

### Management

```bash
# Close positions that have exceeded 24 hours
bin/rake day_trading:close_expired

# Close positions approaching the 24-hour limit
bin/rake day_trading:close_approaching

# Check for and close any TP/SL triggers
bin/rake day_trading:check_tp_sl

# Run the full management cycle (recommended for manual runs)
bin/rake day_trading:manage
```

### Emergency

```bash
# Force-close ALL open day trading positions immediately
bin/rake day_trading:force_close_all

# Cancel all active signals
FORCE=true bin/rake realtime:cancel_all
```

### Maintenance

```bash
# Clean up closed positions older than 30 days
bin/rake day_trading:cleanup
```

## Background Automation

The following jobs run automatically when GoodJob is running:

| Job | Schedule | Purpose |
|-----|----------|---------|
| `DayTradingPositionManagementJob` | Every 15 minutes | Check TP/SL, close expired/approaching positions |
| `EndOfDayPositionClosureJob` | Daily at midnight UTC | Force-close all remaining day trading positions |

Start the GoodJob worker to enable this automation:

```bash
bundle exec good_job start
```

Verify jobs are running via the dashboard:

```
http://localhost:3000/good_job
```

## Risk Rules for Day Trading

| Rule | Value | Notes |
|------|-------|-------|
| Max position duration | 24 hours | Automatically enforced |
| Typical hold time | 1–4 hours | Strategy optimised for this range |
| Take profit target | 40 bps | Hardcoded in `MultiTimeframeSignal` strategy |
| Stop loss target | 30 bps | Hardcoded in `MultiTimeframeSignal` strategy |
| Max signals per hour | 10 (default) | Set via `REALTIME_SIGNAL_MAX_PER_HOUR` |
| Daily loss limit | Manual | Stop trading if equity drops 5% in a day |

## Configuration

Key environment variables for day trading:

```bash
# Enable day trading mode (forces same-day closure)
DEFAULT_DAY_TRADING=true

# Capital and risk
SIGNAL_EQUITY_USD=5000
RISK_PER_TRADE_PERCENT=2

# Signal quality
REALTIME_SIGNAL_MIN_CONFIDENCE=65     # 0–100; higher = fewer but better signals (default: 60)
REALTIME_SIGNAL_MAX_PER_HOUR=8        # Rate limit (default: 10)
REALTIME_SIGNAL_EVALUATION_INTERVAL=45 # Seconds between strategy evaluations (default: 30)

# Duplicate prevention
REALTIME_SIGNAL_DEDUPE_WINDOW=300     # Seconds (default: 300)
```

## Monitoring Positions with the Chat Bot

```bash
bin/rails chat_bot:start
```

```
FuturesBot> show my positions
FuturesBot> what's my P&L?
FuturesBot> how many positions are open?
FuturesBot> display trading summary
```

## Viewing Position Data via API

```bash
# All open day trading positions
curl "http://localhost:3000/api/positions?type=day_trading"

# Position summary with PnL
curl http://localhost:3000/api/positions/summary

# Risk exposure metrics
curl http://localhost:3000/api/positions/exposure
```

## Web Interface

Open the position dashboard in your browser:

```
http://localhost:3000/positions
```

From here you can:
- View all open and closed positions
- Manually create, edit, or close positions
- Increase or decrease position sizes

## Troubleshooting

**Positions not closing automatically**

1. Verify GoodJob is running: `bundle exec good_job start`
2. Check the dashboard: `http://localhost:3000/good_job`
3. Look for errors: `tail -f log/development.log | grep DayTrading`
4. Run manually: `bin/rake day_trading:close_expired`

**TP/SL not triggering**

1. Ensure `COINBASE_API_KEY` and `COINBASE_API_SECRET` are set
2. Verify the bot has a live price feed: `bin/rake market_data:subscribe[BTC-USD]`
3. Check TP/SL values on each position via the web UI or API

**Positions stuck open after 24 hours**

```bash
# Force close all
bin/rake day_trading:force_close_all

# Or via chat bot
# FuturesBot> emergency stop
```

---

**See also:**
- [User Guide](User-Guide) — Full feature walkthrough
- [Trading Strategies](Trading-Strategies) — How signals are generated
- [Risk Management](Risk-Management) — Position sizing and stop controls
- [API Reference](API-Reference) — REST API for position data
- [Troubleshooting](Troubleshooting) — Common issues and solutions
