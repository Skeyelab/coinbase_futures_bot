# Day Trading Guide

This guide covers the repo's day-trading workflows: same-day positions, closure automation, operator tasks, and emergency controls.

## Overview

Day-trading positions are positions with `day_trading=true`. They are expected to close within 24 hours and are managed separately from swing-trading positions.

Related code paths:
- `Trading::DayTradingPositionManager`
- `DayTradingPositionManagementJob`
- `EndOfDayPositionClosureJob`

## Quick Start

```bash
export DEFAULT_DAY_TRADING=true
export SIGNAL_EQUITY_USD=5000
export RISK_PER_TRADE_PERCENT=2
export REALTIME_SIGNAL_MIN_CONFIDENCE=65

bin/rails server
bundle exec good_job start
SIGNAL_EQUITY_USD=5000 bin/rake realtime:signals
```

Monitor in another terminal:

```bash
bin/rake day_trading:check_positions
bin/futuresbot positions --type day
```

## Common Tasks

### Monitoring

```bash
bin/rake day_trading:check_positions
bin/rake day_trading:pnl
bin/rake day_trading:details
```

### Management

```bash
bin/rake day_trading:close_expired
bin/rake day_trading:close_approaching
bin/rake day_trading:check_tp_sl
bin/rake day_trading:manage
```

### Emergency

```bash
bin/rake day_trading:force_close_all
bin/futuresbot halt --reason "day-trading incident"
FORCE=true bin/rake realtime:cancel_all
```

### Maintenance

```bash
bin/rake day_trading:cleanup
```

Note: some operational tasks support or expect `FORCE=true` in non-interactive runs.

## Background Automation

With GoodJob running, the repo schedules day-trading automation through background jobs. At minimum, expect:
- periodic day-trading management
- end-of-day forced closure for remaining day-trading positions

GoodJob dashboard in development:

```text
http://localhost:3000/jobs
```

## Position and Exposure Views

### API

```bash
curl "http://localhost:3000/api/positions?type=day_trading"
curl http://localhost:3000/api/positions/summary
curl http://localhost:3000/api/positions/exposure
```

### Web UI

```text
http://localhost:3000/positions
```

### CLI

```bash
bin/futuresbot status
bin/futuresbot positions --type day
bin/futuresbot signals --min-confidence 75
```

## Useful Configuration

```bash
DEFAULT_DAY_TRADING=true
SIGNAL_EQUITY_USD=5000
RISK_PER_TRADE_PERCENT=2
REALTIME_SIGNAL_MIN_CONFIDENCE=65
REALTIME_SIGNAL_MAX_PER_HOUR=8
REALTIME_SIGNAL_EVALUATION_INTERVAL=45
REALTIME_SIGNAL_DEDUPE_WINDOW=300
```

## Troubleshooting

### Positions are not closing automatically

Check:

```bash
bundle exec good_job start
curl http://localhost:3000/health
bin/rake day_trading:check_positions
bin/rake day_trading:manage
```

Inspect logs:

```bash
tail -f log/development.log | grep -E "DayTrading|Position|GoodJob"
```

### TP/SL actions look stale

Check whether recent market data exists for the product:

```bash
bin/rake "market_data:subscribe[BTC-USD]"
bin/rake realtime:stats
```

### Need to stop everything quickly

```bash
bin/futuresbot halt --reason "operator stop"
bin/futuresbot halt_status
bin/rake day_trading:force_close_all
```

## See Also

- [User Guide](User-Guide)
- [CLI Reference](CLI-Reference)
- [Monitoring](Monitoring)
