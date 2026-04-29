# AGENTS.md

## Learned User Preferences

- Use the caveman skill when available to reduce token usage.
- Prefer concise, smart implementations and brief communication.
- Prefer TDD and keep unit testing as a first-class requirement.
- Keep issue work agent-ready with explicit scope and acceptance criteria.

## Learned Workspace Facts

- This workspace uses `bd` (beads) as the primary issue tracker workflow.
- Running `bd prime` is expected before active issue execution.
- Beads dependency ordering is managed explicitly with `bd dep add`.
- Issue planning often spans both GitHub issues and Beads dependencies.

## What this repo is

- Rails API application for a Coinbase futures trading bot.
- Runtime stack observed in code: Ruby `3.2.4` (`.ruby-version`), Rails `8.x` (`Gemfile`, `config/application.rb`), PostgreSQL, GoodJob, RSpec, StandardRB, Brakeman.
- Important: prose docs are inconsistent about Rails/Ruby versions and project maturity. For operational truth, prefer `Gemfile`, `config/application.rb`, CI workflow, and initializers over README/wiki prose.

## Commands that matter

### Setup and boot

- Install deps: `bundle install`
- Prepare DB: `bin/rails db:prepare`
- Start app: `bin/rails server`
- Health checks:
  - `bin/rails runner 'puts Rails.application.routes.url_helpers.rails_health_check_path'`
  - HTTP endpoints: `/up`, `/health`

### Testing

- Single file / targeted debug: `bundle exec rspec spec/path/to/file_spec.rb`
- Full suite (preferred for whole-repo checks): `bin/parallel_rspec` (YAML-driven) or `bundle exec parallel_rspec` (CLI only; ignores `.parallel_rspec_config` unless you pass flags yourself).
- Coverage run: `COVERAGE=true bundle exec rspec`
- RSpec defaults to random order and documentation formatter via `.rspec`.
- `parallel_rspec` reads `.rspec_parallel` for RSpec options; `bin/parallel_rspec` adds `-n` / `--group-by` / `-s` from `PARALLEL_RSPEC_CONFIG` (default `.parallel_rspec_config`).

### Lint / security

- Ruby style/lint: `bin/standardrb`
- Auto-fix Ruby style: `bin/standardrb --fix`
- Security scan: `bin/brakeman --no-pager`

### Useful runtime entrypoints

- Thor CLI/TUI dashboard: `bin/futuresbot dashboard`
- Chat CLI: `bin/futuresbot chat`
- Realtime signal loop: `bin/rake realtime:signals`
- One-shot realtime evaluation: `bin/rake realtime:evaluate`
- Day trading summary: `bin/rake day_trading:check_positions`
- Day trading close workflow: `bin/rake day_trading:manage`
- Kill switch: `bin/futuresbot halt [--reason "..."]` / `bin/futuresbot resume`

### Beads issue tracker

- List issues: `bd list` / `bd ready`
- Sync with GitHub: `GITHUB_TOKEN="$(gh auth token)" bd github sync`
  - Note: `bd config set github.token` is written to config.yaml but not read by `bd github sync` (bd bug); use the env var workaround above.
- Push to Dolt remote: `bd dolt push` (no remote configured yet)

## High-value gotchas

- `bin/setup` is not a harmless bootstrap script. It also runs `git config core.hooksPath .githooks`. Do not run it casually in automation if you want to avoid mutating local git config.
- `bin/parallel_rspec_local` sets `PARALLEL_RSPEC_CONFIG` to `.parallel_rspec_config.local` and reuses `bin/parallel_rspec` (no file copying).
- The UI credentials used by the positions web UI are `POSITIONS_UI_USERNAME` and `POSITIONS_UI_PASSWORD` (`app/controllers/positions_controller.rb`), while `.env.example` documents different names under “API Authentication”. Trust controller code, not the example text.
- `bin/futuresbot dashboard` and `bin/futuresbot chat` both sync positions from Coinbase on startup unless `FUTURESBOT_SKIP_POSITION_SYNC` is set.
- The repository’s `.env.example` contains credential-like Coinbase values. Treat that file as shape/examples only; never reuse or commit secrets from it.
- CI runs lint and Brakeman first, then tests. CI forces single-process RSpec execution even though local parallel test helpers exist.
- VCR is strict: real HTTP is blocked without a cassette (`spec/support/vcr.rb` sets `allow_http_connections_when_no_cassette = false`). CI record mode is effectively `none`.

## Architecture and control flow

### Main subsystems

- **Market data**: `app/services/market_data/*`
  - REST backfills and product sync via `MarketData::CoinbaseRest`
  - WebSocket subscribers for spot/futures feeds
  - Tick persistence and realtime candle aggregation feed downstream logic
- **Trading/execution**: `app/services/trading/*`, `app/services/execution/*`
  - `Trading::CoinbasePositions` places/adjusts/close orders and mirrors local `Position` rows
  - Day-trading and swing-trading managers enforce lifecycle/risk rules
- **Signals**: `app/services/strategy/*`, `app/services/real_time_signal_evaluator.rb`, `app/models/signal_alert.rb`
  - Strategy output becomes persisted `SignalAlert` rows
  - Realtime evaluator rate-limits and deduplicates alerts before create
- **Position sync/reconciliation**:
  - `PositionImportService` imports exchange positions into local `positions`
  - `PositionReconcileService` closes local `OPEN` rows that are absent from Coinbase snapshots; it does not place orders
- **Chat/CLI**: `lib/cli/*`, `app/services/chat_bot_service.rb`, `app/controllers/api/chat_messages_controller.rb`
  - Thor CLI (`bin/futuresbot`) offers TUI, chat, status, positions, signals
  - Chat API and CLI both route through `ChatBotService`
- **Background jobs / scheduling**: `app/jobs/*`, `config/initializers/good_job.rb`
  - GoodJob is the Active Job adapter
  - Cron jobs cover candles, signals, paper trading, sentiment, day/swing management, expiry, health

### Data flow that matters

1. Coinbase market data enters via REST/WebSocket services.
2. Recent ticks/candles are stored in `ticks` and `candles`.
3. Strategies read candles/ticks and emit signal hashes.
4. `RealTimeSignalEvaluator` validates, deduplicates, and persists `SignalAlert` rows.
5. Trading services place orders and maintain local `Position` state.
6. Import/reconcile services repair drift between Coinbase and local DB.

## Code organization to follow

- `app/services/market_data/*`: exchange/product/candle ingestion
- `app/services/trading/*`: position lifecycle logic
- `app/services/strategy/*`: trading strategy logic
- `app/services/coinbase/*`: API client wrappers/composition
- `app/jobs/*`: scheduled/background execution
- `app/models/*`: persistent state (`Position`, `SignalAlert`, `TradingPair`, `Tick`, `Candle`, chat/sentiment models)
- `lib/tasks/*.rake`: operator tasks
- `lib/cli/*`: Thor CLI and ANSI TUI
- `spec/` mirrors app/lib layout closely enough for direct mapping most of the time

## Patterns and conventions observed

- Service-heavy design; business logic usually lives in service objects, not controllers.
- Local trading state is persisted even for exchange-driven operations. If you change order flows, check both exchange side effects and local `Position` updates.
- Position side conventions are uppercase `LONG` / `SHORT` in `Position`.
- `SignalAlert` validates persisted `side` as `long` / `short` / `unknown`. `SideNormalizer.signal` and `SignalAlert.normalize_side_value` map inbound `buy` / `sell` (and related forms) before save; dedupe and readers may still account for legacy `buy` / `sell` rows in the database.
- Realtime signal configuration lives in `config/initializers/real_time_signals.rb`, not per-service constants.
- `config/api_only = true`, but this app intentionally adds cookies/session/flash middleware back for GoodJob dashboard and the HTML/UI/chat flows.
- Positions UI is not a JSON API controller; `PositionsController` inherits from `ActionController::Base` and uses HTTP Basic auth plus server-rendered views.
- `MarketData::CoinbaseRest` handles multiple Coinbase response shapes defensively; preserve that tolerance when modifying API parsing.

## Testing guidance

- Prefer `rspec` for a single file; prefer `parallel_rspec` for broad confidence.
- Tests run in random order by default; reproduce failures with `--seed <n>`.
- Transactional fixtures are enabled in `spec/rails_helper.rb`.
- Factories are used heavily; `spec/factories/positions.rb` traits encode many lifecycle states (`:yesterday`, `:approaching_closure`, `:swing_trading`, etc.). Reuse those before inventing ad hoc setup.
- There is a mix of integration-style specs using real DB records and selective mocking. `allow_any_instance_of` exists in the suite already, but many newer tests prefer real model/tick/candle setup when feasible.
- VCR uses a custom request matcher that ignores timestamp query params. If an API spec becomes flaky, check cassette naming/matching before changing application code.

## Domain-specific notes agents usually miss

- Futures contract handling is central. Many services assume monthly contract IDs like `BIT-29AUG25-CDE` / `ET-29AUG25-CDE`, not perpetuals.
- `Position#get_current_market_price` and related logic prefer recent `Tick` data, then recent `1m` candles, then give up. Many position-management features depend on that fallback chain.
- `day_trading:*` Rake tasks include interactive confirmation paths; use `FORCE=true` for non-interactive operation where supported.
- `realtime:signals` starts market data subscriptions and then schedules repeated evaluation via `RealTimeSignalJob.start_realtime_evaluation`.
- `RealTimeSignalJob` deletes unfinished scheduled jobs for its own class before scheduling the next run; account for that if changing realtime orchestration.

## Project policy/context from local rule files

- Update `SESSION_NOTES.md` for meaningful work, prepending the newest entry under the first `### Session log` section.
- Use Conventional Commit style when commits are requested.
- Small PRs are preferred; PRs are expected to pass StandardRB and Brakeman.
- StandardRB is the enforced Ruby formatter for `*.rb` and `*.rake`.
- If creating Linear issues for this repo, they belong to project `FuturesBot`, team `FUT`.

## Files worth reading first for most tasks

- `config/application.rb`
- `config/routes.rb`
- `config/initializers/good_job.rb`
- `config/initializers/real_time_signals.rb`
- `app/services/trading/coinbase_positions.rb`
- `app/services/real_time_signal_evaluator.rb`
- `app/models/position.rb`
- `lib/cli/tui_dashboard.rb`
- `spec/rails_helper.rb`
- `spec/support/vcr.rb`
