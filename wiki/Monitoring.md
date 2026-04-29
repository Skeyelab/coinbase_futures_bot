# Monitoring & Observability

## Overview

This page describes the health checks, dashboards, and logging tools available to monitor the Coinbase Futures Bot in development and production.

## Health Checks

### Basic Health — `/up`

Standard Rails health check. Returns `200 OK` when the application is running.

```bash
curl http://localhost:3000/up
# {"status":"ok"}
```

Use this endpoint for:
- Load balancer health checks
- Uptime monitors (e.g., UptimeRobot, Pingdom)
- Deployment verification

### Extended Health — `/health`

Reports database connectivity and connection pool status.

```bash
curl http://localhost:3000/health
```

```json
{
  "status": "healthy",
  "database": {
    "status": "connected",
    "pool_size": 5,
    "connections_in_use": 2
  },
  "timestamp": "2025-01-18T10:30:00Z"
}
```

### Signal System Health — `/signals/health`

Confirms the real-time signal system is active and generating signals.

```bash
curl http://localhost:3000/signals/health
```

```json
{
  "status": "healthy",
  "last_signal_timestamp": "2025-01-18T10:25:00Z",
  "recent_signals_count": 12,
  "active_signals_count": 5,
  "timestamp": "2025-01-18T10:30:00Z"
}
```

### Slack Integration Health — `/slack/health`

Checks that the Slack bot token is valid and the webhook is reachable.

```bash
curl http://localhost:3000/slack/health
```

## GoodJob Dashboard

The GoodJob web interface provides a real-time view of background job queues, scheduled jobs, and failures.

**Access (development only):**

```
http://localhost:3000/good_job
```

From the dashboard you can:
- See queued, running, and failed jobs
- Retry or discard failed jobs
- Monitor job throughput and latency
- Inspect error messages for failing jobs

**Clear stuck jobs via the Rails console:**

```bash
bin/rails console

# Jobs that haven't finished in over an hour
GoodJob::Job.where(finished_at: nil).where("created_at < ?", 1.hour.ago).count

# Discard failed jobs
GoodJob::Job.where.not(error: nil).discard_all
```

## Log Files

```bash
# Application and job logs
tail -f log/development.log

# Filter for trading activity
tail -f log/development.log | grep -E "Signal|Position|DayTrading|RealTime"

# Filter for errors only
tail -f log/development.log | grep -i error
```

Key log patterns to watch:
- `[SignalEvaluator]` — signal generation activity
- `[DayTradingPositionManager]` — position management
- `[ChatBot]` — chat bot commands and responses
- `[SlackNotification]` — Slack alert delivery

## Signal Monitoring

```bash
# Summary of recent signal activity
bin/rake realtime:stats

# Count of active signals
curl -H "X-API-Key: $SIGNALS_API_KEY" http://localhost:3000/signals/stats

# View signals generated in the last hour
curl -H "X-API-Key: $SIGNALS_API_KEY" \
  "http://localhost:3000/signals/recent?hours=1"
```

## Position Monitoring

```bash
# Check all open day trading positions
bin/rake day_trading:check_positions

# View current PnL
bin/rake day_trading:pnl

# Detailed position breakdown
bin/rake day_trading:details
```

Via API:

```bash
curl http://localhost:3000/api/positions/summary
curl http://localhost:3000/api/positions/exposure
```

## Sentry Error Tracking (Optional)

If `SENTRY_DSN` is configured, exceptions are automatically reported to Sentry.

```bash
# .env
SENTRY_DSN=https://your_dsn@sentry.io/project_id
```

See `docs/sentry-monitoring.md` for full setup instructions.

## Slack Alerts

When Slack is configured, the bot automatically posts:

- New trading signals as they are generated
- Position opens, closes, and P&L updates
- System health warnings
- Critical error notifications

See [docs/slack-integration.md](../docs/slack-integration.md) for setup instructions.

## Key Metrics to Watch

| Metric | Healthy Range | How to Check |
|--------|--------------|--------------|
| Active signals | 0–20 | `/signals/stats` |
| Signal confidence | >65% | `/signals/active` |
| Open positions | ≤10 | `/api/positions/summary` |
| Job queue depth | <50 | GoodJob dashboard |
| DB connections in use | <pool_size | `/health` |
| Last signal timestamp | <30 min ago | `/signals/health` |

## Production Checklist

Before going live, verify:

- [ ] `/up` and `/health` return `healthy`
- [ ] GoodJob worker is running with at least 2 threads
- [ ] `DayTradingPositionManagementJob` appears in GoodJob's cron list
- [ ] Slack notifications are delivered to the correct channel
- [ ] Sentry DSN is set (optional but recommended)
- [ ] Log rotation is configured (e.g., `logrotate`)
- [ ] Uptime monitor is pointing at `/up`

---

**See also:**
- [Getting Started](Getting-Started) — Initial setup and prerequisites
- [Deployment Guide](Deployment) — Production deployment steps
- [Troubleshooting](Troubleshooting) — Common issues and solutions
- [Day Trading Guide](Day-Trading-Guide) — Position management automation
