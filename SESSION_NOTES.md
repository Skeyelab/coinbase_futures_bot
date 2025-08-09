### Setup summary

- **Project path**: `/Users/edahl/Documents/Github/coinbase_futures_bot`
- **Ruby/RVM**: `ruby-3.1.3` with gemset `coinbase_futures_bot`
- **Rails**: `7.2.2.1` (API-only)
- **DB**: PostgreSQL via `ENV['DATABASE_URL']` (dev/test respect `PGDATABASE`)
- **Env**: `.env` (gitignored) holds `DATABASE_URL`
- **Job runner**: GoodJob (queue adapter set; migration applied; dashboard mounted in development)

### Database
- **Remote host**: `206.81.1.205:5432`, DB: `postgres`
- **Status**: `bin/rails db:prepare` succeeded; schema version currently `0`

### Resume quickstart
- `rvm use ruby-3.1.3@coinbase_futures_bot`
- `bundle install`
- `bin/rails db:prepare`
- `bin/rails s`

### Next steps
- Configure `config.active_job.queue_adapter = :good_job` and GoodJob settings
- Run GoodJob migration; mount dashboard (optional)
- Implement services: market data, signals, execution, reconciliation
- Add health checks, metrics, and kill switch

### Session log

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
