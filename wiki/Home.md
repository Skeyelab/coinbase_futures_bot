# Coinbase Futures Bot - Documentation Wiki

[![CI Status](https://github.com/Skeyelab/coinbase_futures_bot/workflows/CI/badge.svg)](https://github.com/Skeyelab/coinbase_futures_bot/actions)

Welcome to the documentation wiki for the **Coinbase Futures Bot**. This repo is a Rails 8 futures trading system with market-data ingestion, signal generation, automated position management, a terminal UI, chat tooling, and operational health endpoints.

## Quick Navigation

### Start Here
- **[Getting Started](Getting-Started)** - local setup and boot flow
- **[Configuration](Configuration)** - environment variables and runtime settings
- **[User Guide](User-Guide)** - operator workflows across CLI, API, web UI, and rake tasks
- **[CLI Reference](CLI-Reference)** - exact `bin/futuresbot` command surface
- **[Monitoring](Monitoring)** - health checks, queue visibility, and incident controls

### Core Reference
- **[Architecture](Architecture)** - high-level system design
- **[Database Schema](Database-Schema)** - models and relationships
- **[API Reference](API-Reference)** - HTTP endpoints
- **[Services Guide](Services-Guide)** - major service objects
- **[Background Jobs](Background-Jobs)** - scheduled and asynchronous workflows
- **[Trading Strategies](Trading-Strategies)** - strategy documentation
- **[Testing Guide](Testing-Guide)** - test structure and conventions
- **[Troubleshooting](Troubleshooting)** - common failure modes
- **[Contributing](Contributing)** - contribution workflow

## Project Snapshot

- **Runtime**: Ruby `3.2.4`, Rails `8.x`, PostgreSQL, GoodJob, RSpec, StandardRB, Brakeman
- **Trading model**: both day-trading and swing-trading positions exist
- **Contract model**: repo is centered on expiring Coinbase futures contracts, not perpetuals
- **Primary operator surfaces**: `bin/futuresbot`, `bin/rake`, `/positions`, `/signals/*`, `/health`, `/up`

## Operator Entry Points

### Terminal
- `bin/futuresbot` - default TUI dashboard
- `bin/futuresbot chat` - interactive trading/operator chat
- `bin/futuresbot status` - quick system summary
- `bin/rake realtime:signals` - start the real-time signal loop
- `bin/rake day_trading:manage` - run day-trading management once

### Web / HTTP
- `/up` - basic Rails health
- `/health` - extended application health
- `/positions` - server-rendered positions UI
- `/signals/active`, `/signals/high_confidence`, `/signals/recent`, `/signals/stats`, `/signals/health`
- `/api/positions`, `/api/positions/summary`, `/api/positions/exposure`

### Repository
- **GitHub Repository**: [Skeyelab/coinbase_futures_bot](https://github.com/Skeyelab/coinbase_futures_bot)
- **CI/CD Pipeline**: [GitHub Actions](https://github.com/Skeyelab/coinbase_futures_bot/actions)
- **Issue Tracking**: GitHub Issues

## Notes

- For operational truth, prefer code and current runtime docs over older prose.
- Wiki content syncs from the repository `wiki/` directory on pushes to `main`.

---

**Last Updated**: 2026-06-04
