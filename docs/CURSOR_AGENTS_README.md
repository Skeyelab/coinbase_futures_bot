# Cursor Agents Guidelines

**Prefer [AGENTS.md](../AGENTS.md) at the repo root** — it is kept current for agents. This file summarizes stable conventions; when in doubt, trust `Gemfile.lock`, `config/routes.rb`, and the codebase.

## Technology Stack

| Item | Value |
|------|--------|
| Rails | 8.1.x (`Gemfile`: `~> 8.1.3`) |
| Ruby | 3.2.4 (`.ruby-version`) |
| Database | PostgreSQL |
| Jobs | GoodJob 4.x |
| Tests | RSpec 8 (~109 files, ~2,400 examples) |
| Lint | StandardRB, Brakeman, bundler-audit |

## Futures Contracts

- Live/legacy instruments: monthly dated Coinbase futures (e.g. `BIT-27JUN26-CDE`, `ET-27JUN26-CDE`). Perpetuals (BIP first) are the adopted primary venue per [ADR 0002](adr/0002-perpetual-futures-as-primary-venue.md) but are **not live yet** — do not document perp trading as operational
- Sync catalog: `bin/rake market_data:upsert_futures_products`
- Contract IDs roll; do not hardcode expired examples in docs or tests without reason

## Credentials

- **`cdp_api_key.json`** at repo root (preferred for ES256 keys), or
- **`COINBASE_API_KEY`** + **`COINBASE_API_SECRET`** in `.env`
- Signal API: **`SIGNALS_API_KEY`** (`X-API-Key` header)
- Positions UI: **`POSITIONS_UI_USERNAME`** / **`POSITIONS_UI_PASSWORD`**

## Key Commands

```bash
rvm use ruby-3.2.4@coinbase_futures_bot --create
bundle install && bin/rails db:prepare

bin/futuresbot                    # TUI dashboard
bin/futuresbot start              # TUI + market data + signals
bin/futuresbot halt / resume      # kill switch

bin/parallel_rspec                # full suite (CI)
bundle exec rspec spec/...        # single file
bin/standardrb && bin/brakeman --no-pager

bin/rails server
open http://localhost:3000/jobs   # GoodJob dashboard
curl http://localhost:3000/up
```

## Issue Tracking

- **Primary**: [GitHub Issues](https://github.com/Skeyelab/coinbase_futures_bot/issues)
- **Optional**: [FuturesBot Linear project](https://linear.app/ericdahl/project/futuresbot-c639185ec497/overview)

## Documentation Map

```
docs/           — developer docs (architecture, API, jobs, testing, deployment)
wiki/           — operator wiki
AGENTS.md       — agent quick reference (source of truth for agents)
README.md       — project overview
```

## Common Mistakes

- ❌ `/good_job` URL → ✅ `/jobs` (`config/routes.rb`)
- ❌ Ruby 3.2.2 / Rails 7.2 / 8.0.2 in new docs
- ❌ Stale contract IDs like `BIT-29AUG25-CDE`
- ❌ Calling the app "API-only" without noting Positions/Chat HTML UI
- ❌ `bundle exec rspec` for full CI parity → use `bin/parallel_rspec`

## Last Updated

2026-06-08 — aligned with README refresh and `AGENTS.md`.
