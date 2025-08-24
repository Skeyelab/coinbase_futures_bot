# Cursor Agents Guidelines

## Critical Project Information

**READ THIS FIRST** - This file contains essential information for Cursor agents working on this project.

### Project Specifications

#### Technology Stack (Verified 2025-01-17)
- **Rails Version**: 8.0.2.1 (NOT 7.2.x)
- **Ruby Version**: 3.2.2 (NOT 3.2.4)
- **Database**: PostgreSQL
- **Job Processing**: GoodJob 4.11
- **Testing**: RSpec

#### Futures Contract Handling
- **ONLY Current Month Contracts**: The system exclusively handles current month futures contracts
- **NO Perpetual Support**: Perpetual contracts (-PERP) are NOT supported
- **Contract Examples**: BIT-29AUG25-CDE, ET-29AUG25-CDE
- **Automatic Rollover**: Built-in contract rollover and expiration management

#### Current System Stats (Verified 2025-01-17)
- **Services**: 18 service files in `app/services/`
- **Jobs**: 10 background job files in `app/jobs/`
- **Models**: 5 core database models
- **Tests**: 21 spec files in `spec/`
- **Strategies**: 3 trading strategies implemented

### Key Architecture Decisions

#### Contract Resolution
All asset symbols (BTC, ETH) automatically resolve to current month contracts:
- `BTC` → Current month BTC contract (e.g., `BIT-29AUG25-CDE`)
- `ETH` → Current month ETH contract (e.g., `ET-29AUG25-CDE`)

#### Database Schema
- Uses `expiration_date` and `contract_type` fields
- NO `is_perpetual` field (was removed)
- Scopes: `.current_month`, `.upcoming_month`, `.tradeable`, `.active`

#### Trading Strategy Flow
1. Multi-timeframe analysis (1h → 15m → 5m → 1m)
2. Sentiment filtering (z-score based)
3. Automatic contract resolution
4. Risk management and position sizing

### Documentation Structure

```
docs/
├── CURSOR_AGENTS_README.md    # This file - READ FIRST
├── architecture.md             # System design overview
├── development.md             # Setup and development workflow
├── testing.md                 # Testing strategy and patterns
├── configuration.md           # Environment variables and setup
├── deployment.md             # Production deployment guide
├── strategies.md              # Trading strategies documentation
├── database-schema.md         # Database models and relationships
├── api-endpoints.md          # REST API documentation
├── jobs.md                   # Background job system
└── services/                 # Service layer documentation
    ├── README.md             # Service overview
    └── market-data.md        # Market data services
```

### Common Mistakes to Avoid

#### Version References
- ❌ Don't reference Rails 7.2.x
- ✅ Use Rails 8.0.x
- ❌ Don't reference Ruby 3.2.4
- ✅ Use Ruby 3.2.2

#### Contract Types
- ❌ Don't implement perpetual contract logic
- ✅ Focus only on current month contracts
- ❌ Don't use -PERP suffixes
- ✅ Use actual contract IDs like BIT-29AUG25-CDE

#### Setup Instructions
- ❌ `rvm use ruby-3.2.4@coinbase_futures_bot`
- ✅ `rvm use ruby-3.2.2@coinbase_futures_bot`

### Development Environment

#### Required Environment Variables
```bash
DATABASE_URL=postgresql://localhost:5432/coinbase_futures_bot_development
COINBASE_API_KEY=your_api_key
COINBASE_API_SECRET=your_api_secret
CRYPTOPANIC_TOKEN=your_token
```

#### Key Commands
```bash
# Setup
bundle install
bin/rails db:prepare

# Testing
bundle exec rspec
bin/standardrb
bundle exec brakeman

# Development
bin/rails server
open http://localhost:3000/good_job  # Job dashboard
```

### Project Goals

1. **Current Month Futures Trading**: Automated trading of monthly futures contracts
2. **Multi-timeframe Analysis**: 1h trend → 15m confirmation → 5m/1m execution
3. **Sentiment Integration**: News-based signal filtering
4. **Risk Management**: Position sizing, stop losses, contract rollover
5. **Paper Trading**: Comprehensive simulation and backtesting

### Linear Project Management

- **Project**: FuturesBot (ID: f71902c7-f796-49c9-b27c-488a5f8d95d2)
- **Team**: FuturesBot (ID: 2552b0b1-b069-4e3b-ad4f-a5673ac753c0)
- **URL**: https://linear.app/ericdahl/project/futuresbot-c639185ec497/overview

### Git Workflow

- **Branch Strategy**: Feature branches with PRs
- **Commit Style**: Conventional Commits
- **CI/CD**: GitHub Actions (StandardRB, Brakeman, RSpec)
- **Email**: Use eric@skeyelab.com for git commits

### Last Updated

This file was last verified and updated on **2025-01-17** during the comprehensive documentation review (FUT-8).

### Questions?

If you find inconsistencies between this file and the codebase, prioritize:
1. **This file** for project specifications
2. **Actual codebase** for implementation details
3. **Recent git commits** for latest changes

Report any discrepancies as they may indicate documentation needs updating.
