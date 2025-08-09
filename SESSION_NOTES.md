### Session notes (trading bot setup)

- **Project path**: `/Users/edahl/Documents/Github/coinbase_futures_bot`
- **Ruby/RVM**: `ruby-3.1.3` with gemset `coinbase_futures_bot` (see `.ruby-version`, `.ruby-gemset`)
- **Rails**: `7.2.2.1` (API-only app)

### Database
- **Driver**: PostgreSQL
- **Config**: uses `ENV['DATABASE_URL']`
- **.env**: created and gitignored; contains `DATABASE_URL` for the remote DB
- **Remote host**: `206.81.1.205:5432`, DB: `postgres`
- **Status**: `bin/rails db:prepare` succeeded against remote; schema version currently `0`

### Changes made
- Added `dotenv-rails` in development/test to load env vars
- Updated `config/database.yml` to read from `ENV['DATABASE_URL']` and respect `PGDATABASE`
- Initial Rails app generated (API-only, PostgreSQL) and committed

### Resume quickstart
- `➜ coinbase_futures_bot rvm use ruby-3.1.3@coinbase_futures_bot`
- `➜ coinbase_futures_bot bundle install`
- `➜ coinbase_futures_bot bin/rails db:prepare`
- `➜ coinbase_futures_bot bin/rails s`

### Next steps (suggested)
- Add GoodJob (job runner), queues, and concurrency limits
- Implement services: market data subscriber, signal generation, execution, reconciliation
- Add health checks, metrics, and kill switch


