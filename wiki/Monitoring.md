# Monitoring

This page collects the main health, queue, log, and operator controls for the current repo.

## Health Endpoints

### Rails health

```bash
curl http://localhost:3000/up
```

### Extended app health

```bash
curl http://localhost:3000/health
```

### Signal system health

```bash
curl http://localhost:3000/signals/health
```

### Slack health

```bash
curl http://localhost:3000/slack/health
```

## Queue / Background Jobs

Start worker locally:

```bash
bundle exec good_job start
```

Development dashboard:

```text
http://localhost:3000/good_job
```

Use it to inspect:
- queued jobs
- failed jobs
- retries / reschedules
- cron-backed recurring work

## CLI Monitoring

```bash
bin/futuresbot
bin/futuresbot status
bin/futuresbot positions
bin/futuresbot signals --min-confidence 75
bin/futuresbot halt_status
```

## Signal Monitoring

```bash
bin/rake realtime:stats
curl -H "X-API-Key: $SIGNALS_API_KEY" http://localhost:3000/signals/active
curl -H "X-API-Key: $SIGNALS_API_KEY" "http://localhost:3000/signals/stats?hours=24"
curl -H "X-API-Key: $SIGNALS_API_KEY" "http://localhost:3000/signals/recent?hours=1"
```

## Position Monitoring

```bash
bin/rake day_trading:check_positions
bin/rake day_trading:pnl
curl http://localhost:3000/api/positions/summary
curl http://localhost:3000/api/positions/exposure
```

## Logs

Application log:

```bash
tail -f log/development.log
```

Useful filters:

```bash
tail -f log/development.log | grep -E "Signal|Position|Coinbase|GoodJob|TradingHalt"
tail -f log/development.log | grep -i error
```

## Incident Controls

Kill switch:

```bash
bin/futuresbot halt --reason "incident"
bin/futuresbot halt_status
bin/futuresbot resume
```

Signal cleanup:

```bash
FORCE=true bin/rake realtime:cancel_all
bin/rake realtime:cleanup
```

## Local Readiness Checklist

- `/up` returns success
- `/health` returns success
- GoodJob worker is running
- `/signals/health` is reachable if signal workflows matter for the task
- `bin/futuresbot halt_status` shows expected kill-switch state
- `SIGNALS_API_KEY` is set before using authenticated signal endpoints

## See Also

- [User Guide](User-Guide)
- [CLI Reference](CLI-Reference)
- [Day-Trading-Guide](Day-Trading-Guide)
