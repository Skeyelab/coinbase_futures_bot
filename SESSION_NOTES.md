### Setup summary

- **Project path**: `/Users/edahl/Documents/Github/coinbase_futures_bot`
- **Ruby/RVM**: `ruby-3.2.2` with gemset `coinbase_futures_bot` (Rails 8 requires >= 3.2; 3.2.4 compile failed locally)
- **Rails**: `7.2.2.1` (API-only)
- **DB**: PostgreSQL via `ENV['DATABASE_URL']` (dev/test respect `PGDATABASE`)
- **Env**: `.env` (gitignored) holds `DATABASE_URL`
- **Job runner**: GoodJob (queue adapter set; migration applied; dashboard mounted in development)
- **Purpose**: Coinbase futures trading bot (market data → signals → execution → reconciliation)

### Database
- **Remote host**: `206.81.1.205:5432`, DB: `postgres`
- **Status**: `bin/rails db:prepare` succeeded; schema version currently `0`

### Resume quickstart
- `rvm use ruby-3.2.4@coinbase_futures_bot`
- `bundle install`
- `bin/rails db:prepare`
- `bin/rails s`

### Next steps
- Implement services: market data subscriber, signal generation, execution, reconciliation
- Add health checks (`/up` ok), metrics, and kill switch
- Wire Coinbase Futures API integration and secrets via env vars
- Configure branch protection required checks after CI green

### Session log

#### 2025-08-12 17:08 UTC
- Context: Coinbase Advanced Trade auth failing with 401; aligned JWT generation and endpoints to docs.
- Changes:
  - Updated `app/services/coinbase/advanced_trade_client.rb` to:
    - Include `aud: "retail_rest_api"` and sign URI including query for GET/DELETE.
    - Fix margin window endpoint to `/api/v3/brokerage/cfm/intraday/current_margin_window`.
    - Reduce JWT logging (no token fragments in logs).
- Commands run:
  - `ruby scripts/generate_jwt_and_curl.rb GET /api/v3/brokerage/accounts`
  - `curl -s -D - -H "Authorization: Bearer $JWT" -H "Accept: application/json" 'https://api.coinbase.com/api/v3/brokerage/accounts' | cat`
- Files touched:
  - `app/services/coinbase/advanced_trade_client.rb`, `SESSION_NOTES.md`
- Next steps:
  - Verify API key status/permissions and IP allowlist in CDP portal.
  - Ensure system clock correct; retry `accounts` and `cfm/positions` endpoints.
  - Add an integration spec to exercise JWT signing for GET with query params.

#### 2025-08-12 03:19 UTC
- Context: RSpec failures due to leftover records in shared test DB; cleaned setup and verified green suite.
- Changes:
  - Added per-example cleanup of `Candle`, `TradingPair`, and `Tick` in `spec/rails_helper.rb` to avoid cross-test interference.
- Commands run:
  - `bundle exec rspec`
- Files touched:
  - `spec/rails_helper.rb`, `SESSION_NOTES.md`
- Next steps:
  - Keep tests isolated; consider using database cleaner strategies if needed in future.

#### 2025-08-12  — Minitest → RSpec migration
- Context: Replace Minitest with RSpec across the project and adjust CI.
- Changes:
  - Added `rspec-rails` and `climate_control` gems; generated RSpec config (`.rspec`, `spec/*`).
  - Converted tests to RSpec: models, services, jobs, requests, and rake tasks.
  - Updated generators to use RSpec; removed `rails/test_unit/railtie`.
  - Updated CI workflow to run `bundle exec rspec`.
  - Removed legacy `test/` directory and Minitest files.
- Commands run:
  - Edited `Gemfile`, created `spec/` files, updated `.github/workflows/test.yml`.
- Files touched:
  - `Gemfile`, `config/application.rb`, `.rspec`, `spec/**/*`, `.github/workflows/test.yml`, `README.md`.
- Next steps:
  - Run bundler and `rspec` locally/CI to refresh `Gemfile.lock` and validate tests.
#### 2025-08-12 20:30 UTC
- Context: Sanitize MCP config to read token from environment.
- Changes:
  - Updated `.cursor/mcp.json` to use `${GITHUB_TOKEN}` rather than a hardcoded PAT.
- Commands run:
  - n/a (file edit only)
- Files touched:
  - `.cursor/mcp.json`, `SESSION_NOTES.md`
- Next steps:
  - Ensure `GITHUB_TOKEN` is set in Cursor app environment before starting sessions.

#### 2025-08-12 20:22 UTC
- Context: Align dev container with Cursor background agent guidance and improve cloning ergonomics.
- Changes:
  - Updated `.cursor/Dockerfile` to add `openssh-client`, ensure Yarn availability (`npm i -g yarn`), and set `WORKDIR` to `/home/dev` with correct ownership.
  - Bundler remains pinned to `2.7.1` per `Gemfile.lock`.
- Commands run:
  - n/a (file edits only)
- Files touched:
  - `.cursor/Dockerfile`, `SESSION_NOTES.md`
- Next steps:
  - Rebuild: `docker build -f .cursor/Dockerfile -t coinbase-futures-bot-dev .`
  - Start container and clone repo; run `bundle install`.

#### 2025-08-12 20:05 UTC
- Context: Added a developer-focused container for Cursor background agent.
- Changes:
  - Created `.cursor/Dockerfile` with Ruby 3.2.2, Bundler 2.7.1, PostgreSQL client, Node/npm, and common CLI dev tools. Does not copy app code; intended for cloning post-build.
- Commands run:
  - `docker build -f .cursor/Dockerfile -t coinbase-futures-bot-dev .`
- Files touched:
  - `.cursor/Dockerfile`, `SESSION_NOTES.md`
- Next steps:
  - Start container, clone repo inside `/workspace`, run `bundle install` and `bin/rails db:prepare`.

#### 2025-08-11 19:25 UTC
- Context: Fixed inline WebSocket subscription crash due to instance_exec scoping in event handlers.
- Changes:
  - Updated `app/services/market_data/coinbase_futures_subscriber.rb` to bind handlers with captured references so `subscribe` and logger calls work
  - Added `mark_ws_as_closed` to reliably end the sleep loop on close
- Commands run:
  - `INLINE=1 bin/rake "market_data:subscribe[BTC-USD-PERP]"`
- Files touched:
  - `app/services/market_data/coinbase_futures_subscriber.rb`, `SESSION_NOTES.md`
- Next steps:
  - Monitor ticker output; implement normalization/enqueue to strategy engine
  - Add metrics and basic reconnect/backoff logic

#### 2025-08-09 05:12 UTC
- Context: CI stabilized; automation and ownership set; notes updated for project purpose and Ruby 3.2.4.
- Changes:
  - Consolidated CI (RuboCop + Brakeman); fixed migration style; bumped Ruby to 3.2.4
  - Added Dependabot (bundler, actions) and CODEOWNERS (@Skeyelab)
  - Created issue to enable branch protection with required checks
  - Updated `SESSION_NOTES` setup summary, quickstart, and next steps
- Commands run:
  - `git add` / `git commit` / `git push`
- Files touched:
  - `.github/workflows/ci.yml`, `.github/dependabot.yml`, `.github/CODEOWNERS`
  - `.ruby-version`, `db/migrate/20250809042439_create_good_jobs.rb`, `SESSION_NOTES.md`
- Next steps:
  - Enable branch protection in repo settings; proceed to implement market data service

#### 2025-08-09 05:14 UTC
- Context: Rails upgrade to 8.0.2; local Ruby aligned to 3.2.x.
- Changes:
  - Switched to Ruby 3.2.2 via RVM (3.2.4 failed to compile on this host)
  - Upgraded Rails gems to 8.0.2; updated `config.load_defaults` to 8.0
- Commands run:
  - `rvm use 3.2.2@coinbase_futures_bot --create`
  - `bundle update rails && bundle install`
- Files touched:
  - `Gemfile`, `Gemfile.lock`, `config/application.rb`, `.ruby-version`
- Next steps:
  - Optionally retry Ruby 3.2.4 later; proceed with service scaffolding on Rails 8

#### 2025-08-09 05:06 UTC
- Context: MCP GitHub identity switched successfully to `Skeyelab`.
- Changes:
  - Updated local `.cursor/mcp.json` with Skeyelab PAT (file is gitignored)
- Verification:
  - Authenticated user now reports as `Skeyelab`
- Next steps:
  - Use MCP GitHub actions under `Skeyelab` for PRs/issues as needed

#### 2025-08-09 05:00 UTC
- Context: Re-verified MCP GitHub auth after `.env` update.
- Outcome: Authenticated user is still `edahl_UND` (MCP reads process env, not `.env`).
- Next steps:
  - Ensure `GITHUB_TOKEN` for Skeyelab is in the Cursor app process environment.
  - Easiest: start Cursor from a terminal session with the var set:
    - `export GITHUB_TOKEN="<Skeyelab_PAT>" && open -a Cursor`
  - Or set a system/user environment var so GUI apps inherit it, then restart Cursor.

#### 2025-08-09 04:52 UTC
- Context: Validated MCP GitHub connectivity and sanitized token usage.
- Changes:
  - Updated `.cursor/mcp.json` to use `${GITHUB_TOKEN}` instead of hardcoded PAT
  - Verified current authenticated user via MCP
- Commands run:
  - `mcp github get_me` (via tool) → user `edahl_UND`
- Files touched:
  - `.cursor/mcp.json`, `SESSION_NOTES.md`
- Next steps:
  - To use `Skeyelab`, set `GITHUB_TOKEN` to a PAT from that account, then reload MCP and re-check

#### 2025-08-09 04:34 UTC
- Context: Added commit checkpoint rule; sanitized MCP token; created local checkpoint commit.
- Changes:
  - Created `.cursor/rules/commit-checkpoints.mdc`
  - Sanitized `.cursor/mcp.json` to use `${GITHUB_TOKEN}`
  - Committed GoodJob setup, rules, and `TestJob`
- Commands run:
  - `git add -A`
  - `git commit -m "feat(jobs): add GoodJob and configure adapter/dashboard; verify with TestJob ..."`
  - `git push` (skipped: no remote configured)
- Files touched:
  - `.cursor/rules/commit-checkpoints.mdc`, `.cursor/mcp.json`
- Next steps:
  - Configure git remote and push (`git remote add origin <url>`; `git push -u origin main`)

#### 2025-08-09 04:30 UTC
- Context: GoodJob configured and migrated; dashboard available in development.
- Changes:
  - Set `config.active_job.queue_adapter = :good_job` in `config/application.rb`
  - Added GoodJob initializer `config/initializers/good_job.rb` with sane defaults and env overrides
  - Mounted dashboard at `/good_job` in development in `config/routes.rb`
  - Applied GoodJob migration (tables created)
- Commands run:
  - `bin/rails db:migrate`
  - `bin/rails db:migrate:status | cat`
- Files touched:
  - `config/application.rb`
  - `config/initializers/good_job.rb`
  - `config/routes.rb`
- Migrations:
  - `20250809042439_create_good_jobs.rb` (state: migrated)
- Next steps:
  - Enqueue a test job to verify execution (`async` mode by default)
  - Tune `GOOD_JOB_MAX_THREADS`, `GOOD_JOB_QUEUES` in prod
  - Implement market data, signals, execution, reconciliation services

#### 2025-08-09 04:32 UTC
- Context: Verified GoodJob end-to-end execution.
- Changes:
  - Added `app/jobs/test_job.rb`
  - Enqueued `TestJob.perform_later("It works")` and ran inline execution
- Commands run:
  - `bin/rails runner 'TestJob.perform_later("It works")'`
  - `bin/rails runner 'TestJob.perform_now("Inline OK")'`
  - `GOOD_JOB_EXECUTION_MODE=inline bin/rails runner 'TestJob.perform_later("Inline via GoodJob")'`
  - `bin/rails runner 'puts({jobs: GoodJob::Job.count, executions: GoodJob::Execution.count}.inspect); ...'`
- Files touched:
  - `app/jobs/test_job.rb`
- Verification:
  - Jobs: 2, Executions: 1; last job finished with no error
- Next steps:
  - Remove or keep `TestJob` for smoke tests
  - Begin implementing real jobs (e.g., market data subscriber)

#### 2025-08-09 04:25 UTC
- Context: Baseline Rails API app connected to remote Postgres; beginning background job setup.
- Changes:
  - Added `good_job` gem
  - Generated GoodJob migration: `db/migrate/20250809042439_create_good_jobs.rb`
  - Created Cursor rule to log sessions: `.cursor/rules/session-notes.mdc`
- Commands run:
  - `bundle add good_job`
  - `bin/rails generate good_job:install --force --skip-mount`
- Files touched:
  - `Gemfile`, `Gemfile.lock`
  - `db/migrate/20250809042439_create_good_jobs.rb`
  - `.cursor/rules/session-notes.mdc`
- Migrations:
  - `20250809042439_create_good_jobs.rb` (state: created, not migrated)
- Next steps:
  - Set `config.active_job.queue_adapter = :good_job`
  - Create GoodJob initializer for concurrency/queues
  - `bin/rails db:migrate`

#### 2025-08-12
- Context: Ensure candle data collection is working and documented.
- Changes:
  - Fixed `FetchCandlesJob` start_time selection to use the later of last-candle+1h and backfill window.
  - Added `docs/candles.md` detailing schema, fetching paths, cron, env, and troubleshooting.
  - Updated `README.md` with a Candle data collection section linking to the docs.
- Next steps:
  - Run test suite locally (requires Ruby/Bundler) and verify GoodJob cron executes `FetchCandlesJob`.


