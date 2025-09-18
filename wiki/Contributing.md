# Contributing

## Overview

Welcome to the coinbase_futures_bot project! This guide outlines the development workflow, coding standards, and contribution process for maintaining high-quality code and collaborative development.

## Development Workflow

### 1. Getting Started

#### Fork and Clone
```bash
# Fork the repository on GitHub
# Then clone your fork
git clone git@github.com:YOUR_USERNAME/coinbase_futures_bot.git
cd coinbase_futures_bot

# Add upstream remote
git remote add upstream git@github.com:Skeyelab/coinbase_futures_bot.git
```

#### Setup Development Environment
```bash
# Use Ruby 3.2.4 with project gemset
rvm use ruby-3.2.4@coinbase_futures_bot --create

# Install dependencies
bundle install

# Setup database
bin/rails db:prepare

# Run tests to verify setup
bundle exec rspec
```

### 2. Branch Strategy

#### Branch Naming Convention
```bash
# Feature branches
git checkout -b feature/signal-confidence-scoring
git checkout -b feature/add-sentiment-filtering

# Bug fix branches  
git checkout -b fix/websocket-connection-drops
git checkout -b fix/position-calculation-error

# Hotfix branches (for production issues)
git checkout -b hotfix/api-rate-limit-exceeded

# Documentation branches
git checkout -b docs/update-api-reference
```

#### Branch Lifecycle
```bash
# Start new feature
git checkout main
git pull upstream main
git checkout -b feature/your-feature-name

# Work on feature with regular commits
git add .
git commit -m "feat: implement basic signal confidence scoring"

# Keep branch updated with main
git fetch upstream
git rebase upstream/main

# Push to your fork
git push origin feature/your-feature-name

# Create Pull Request on GitHub
```

### 3. Commit Standards

#### Conventional Commits
We use [Conventional Commits](https://www.conventionalcommits.org/) for consistent commit messages:

```bash
# Format: <type>[optional scope]: <description>

# Types:
feat:     # New feature
fix:      # Bug fix
docs:     # Documentation changes
style:    # Code style changes (formatting, etc.)
refactor: # Code refactoring
test:     # Adding or modifying tests
chore:    # Maintenance tasks
perf:     # Performance improvements
ci:       # CI/CD changes
```

#### Commit Examples
```bash
# Good commit messages
feat(strategy): add sentiment z-score filtering to signal generation
fix(api): handle rate limit errors with exponential backoff
docs(readme): update installation instructions for macOS
test(services): add comprehensive tests for MultiTimeframeSignal
refactor(jobs): extract common job retry logic to concern
perf(database): optimize candle queries with better indexing

# Bad commit messages (avoid these)
git commit -m "fix stuff"
git commit -m "update code"
git commit -m "changes"
```

#### Commit Best Practices
```bash
# Make atomic commits (one logical change per commit)
git add app/services/strategy/multi_timeframe_signal.rb
git commit -m "feat(strategy): implement EMA crossover detection"

git add spec/services/strategy/multi_timeframe_signal_spec.rb
git commit -m "test(strategy): add tests for EMA crossover detection"

# Write descriptive commit messages
# - Use imperative mood ("add" not "added")
# - Explain what and why, not how
# - Keep first line under 50 characters
# - Add detailed description if needed
```

## Coding Standards

### 1. Ruby Style Guide

#### StandardRB Compliance
We use [StandardRB](https://github.com/standardrb/standard) for code formatting and style:

```bash
# Check code style
bin/standardrb

# Auto-fix style issues
bin/standardrb --fix

# Run before every commit
git add .
bin/standardrb --fix
git add .  # Add any auto-fixes
git commit -m "your commit message"
```

#### Key Style Guidelines
```ruby
# Use double quotes for strings
name = "coinbase_futures_bot"

# Use trailing commas in multi-line arrays/hashes
config = {
  api_key: ENV["COINBASE_API_KEY"],
  timeout: 30,
  retries: 3,  # <- trailing comma
}

# Use descriptive variable names
user_positions = Position.where(user_id: current_user.id)
# Not: positions = Position.where(user_id: current_user.id)

# Use early returns to reduce nesting
def process_signal(signal)
  return nil unless signal.valid?
  return nil unless signal.confidence > threshold
  
  execute_signal(signal)
end
```

### 2. Rails Conventions

#### Model Guidelines
```ruby
class Position < ApplicationRecord
  # Order: constants, associations, validations, scopes, callbacks, methods
  
  # Constants first
  VALID_SIDES = %w[LONG SHORT].freeze
  
  # Associations
  belongs_to :trading_pair, optional: true
  
  # Validations
  validates :product_id, presence: true
  validates :side, inclusion: { in: VALID_SIDES }
  
  # Scopes
  scope :open, -> { where(status: "OPEN") }
  scope :day_trading, -> { where(day_trading: true) }
  
  # Callbacks
  before_validation :set_defaults
  after_create :log_position_opened
  
  # Instance methods
  def open?
    status == "OPEN"
  end
  
  private
  
  def set_defaults
    self.status ||= "OPEN"
  end
end
```

#### Service Guidelines
```ruby
class Strategy::MultiTimeframeSignal
  include SentryServiceTracking
  
  def initialize(config = {})
    @config = default_config.merge(config)
    @logger = Rails.logger
  end
  
  def signal(symbol:, equity_usd:)
    track_service_call("signal_generation", symbol: symbol) do
      # Service logic here
    end
  end
  
  private
  
  def default_config
    {
      ema_1h_short: 21,
      ema_1h_long: 50,
      # ... other defaults
    }
  end
end
```

#### Controller Guidelines
```ruby
class SignalController < ApplicationController
  before_action :authenticate_request, except: [:health]
  before_action :set_cors_headers
  
  # GET /signals
  def index
    signals = SignalAlert.active.includes(:trading_pair)
    signals = filter_signals(signals)
    signals = signals.page(params[:page]).per(params[:per_page] || 50)
    
    render json: {
      signals: signals.map(&:to_api_response),
      meta: pagination_meta(signals)
    }
  end
  
  private
  
  def filter_signals(signals)
    signals = signals.for_symbol(params[:symbol]) if params[:symbol]
    signals = signals.high_confidence(params[:min_confidence]) if params[:min_confidence]
    signals
  end
  
  def pagination_meta(paginated_collection)
    {
      total_count: paginated_collection.total_count,
      current_page: paginated_collection.current_page,
      per_page: paginated_collection.limit_value,
      total_pages: paginated_collection.total_pages
    }
  end
end
```

### 3. Testing Standards

#### Test Organization
```ruby
# spec/services/strategy/multi_timeframe_signal_spec.rb
RSpec.describe Strategy::MultiTimeframeSignal do
  let(:strategy) { described_class.new }
  let(:symbol) { "BTC-USD" }
  
  describe '#signal' do
    context 'with sufficient data' do
      before do
        create_test_candles(symbol)
      end
      
      context 'when trend is bullish' do
        it 'generates long signal' do
          # Test implementation
        end
        
        it 'includes correct metadata' do
          # Test implementation
        end
      end
      
      context 'when sentiment is neutral' do
        it 'filters out signal' do
          # Test implementation
        end
      end
    end
    
    context 'with insufficient data' do
      it 'returns nil' do
        # Test implementation
      end
    end
  end
  
  private
  
  def create_test_candles(symbol)
    # Test helper implementation
  end
end
```

#### Test Best Practices
```ruby
# Use descriptive test names
it 'calculates position size based on Kelly criterion'
it 'applies sentiment filter when z-score is below threshold'
it 'sends Slack notification when high-confidence signal is generated'

# Use proper test data setup
let(:position) { create(:position, :day_trading, entry_price: 45000) }
let(:signal) { build(:signal_alert, confidence: 85, symbol: 'BTC-USD') }

# Test one thing per test
it 'validates presence of product_id' do
  position = build(:position, product_id: nil)
  expect(position).not_to be_valid
  expect(position.errors[:product_id]).to include("can't be blank")
end

# Use proper mocking
it 'calls external API with correct parameters' do
  api_client = instance_double(Coinbase::AdvancedTradeClient)
  allow(Coinbase::AdvancedTradeClient).to receive(:new).and_return(api_client)
  
  expect(api_client).to receive(:get_accounts).and_return([])
  
  service.fetch_accounts
end
```

### 4. Documentation Standards

#### Code Documentation
```ruby
class Strategy::MultiTimeframeSignal
  # Multi-timeframe trading strategy for day trading futures
  # 
  # Analyzes 1h trend, 15m confirmation, 5m entry, and 1m timing
  # to generate high-confidence trading signals with tight risk management.
  #
  # @example Generate signal for BTC
  #   strategy = Strategy::MultiTimeframeSignal.new
  #   signal = strategy.signal(symbol: "BTC-USD", equity_usd: 50000)
  #
  # @param symbol [String] Trading pair symbol (e.g., "BTC-USD")
  # @param equity_usd [Float] Available equity for position sizing
  # @return [Hash, nil] Signal hash with entry/exit prices or nil if no signal
  def signal(symbol:, equity_usd:)
    # Implementation
  end
  
  private
  
  # Calculates position size using Kelly criterion with conservative scaling
  #
  # @param win_rate [Float] Historical win rate (0.0 to 1.0)
  # @param avg_win [Float] Average winning trade amount
  # @param avg_loss [Float] Average losing trade amount (positive number)
  # @param equity [Float] Available equity
  # @return [Integer] Position size in contracts
  def calculate_kelly_position_size(win_rate, avg_win, avg_loss, equity)
    # Implementation
  end
end
```

#### README and Wiki Updates
- Update README.md for significant feature changes
- Add new wiki pages for major features
- Update configuration documentation for new environment variables
- Include examples and usage patterns

## Pull Request Process

### 1. Pre-Pull Request Checklist

```bash
# Before creating a pull request, ensure:

# 1. Code follows style guidelines
bin/standardrb --fix

# 2. All tests pass
bundle exec rspec

# 3. Security scan passes
bundle exec brakeman

# 4. No linting errors
bin/standardrb

# 5. Documentation is updated
# - Update relevant wiki pages
# - Add/update code comments
# - Update README if needed

# 6. Commit messages follow conventions
git log --oneline -10  # Review recent commits
```

### 2. Pull Request Template

When creating a pull request, use this template:

```markdown
## Description
Brief description of changes and motivation.

## Type of Change
- [ ] Bug fix (non-breaking change which fixes an issue)
- [ ] New feature (non-breaking change which adds functionality)
- [ ] Breaking change (fix or feature that would cause existing functionality to not work as expected)
- [ ] Documentation update
- [ ] Performance improvement
- [ ] Code refactoring

## Testing
- [ ] Unit tests added/updated
- [ ] Integration tests added/updated
- [ ] Manual testing completed
- [ ] All existing tests pass

## Checklist
- [ ] Code follows project style guidelines (StandardRB)
- [ ] Self-review of code completed
- [ ] Code is commented, particularly in hard-to-understand areas
- [ ] Corresponding changes to documentation made
- [ ] No new warnings introduced
- [ ] Security scan passes (Brakeman)

## Screenshots (if applicable)
Add screenshots for UI changes.

## Related Issues
Closes #123
Fixes #456
```

### 3. Pull Request Review Process

#### For Contributors
```bash
# Address review feedback
git checkout feature/your-branch
# Make requested changes
git add .
git commit -m "fix: address PR review feedback"
git push origin feature/your-branch

# Keep PR updated with main
git fetch upstream
git rebase upstream/main
git push --force-with-lease origin feature/your-branch
```

#### For Reviewers
Review checklist:
- [ ] Code follows project standards
- [ ] Tests are comprehensive and pass
- [ ] Documentation is adequate
- [ ] Security considerations addressed
- [ ] Performance impact considered
- [ ] Breaking changes identified and documented

### 4. Merge Requirements

Pull requests must meet these requirements before merging:

1. **CI Passes**: All GitHub Actions checks pass
2. **Code Review**: At least one approving review from maintainer
3. **Tests**: Comprehensive test coverage for new code
4. **Documentation**: Updated documentation for user-facing changes
5. **Standards**: Code follows StandardRB and project conventions

## Issue Tracking

### 1. Linear Integration

All issues are tracked in Linear under the **FuturesBot** project:

- **Project URL**: [FuturesBot Project](https://linear.app/ericdahl/project/futuresbot-c639185ec497/overview)
- **Team**: FUT
- **Labels**: bug, feature, enhancement, trading, risk, documentation

### 2. Issue Creation Guidelines

#### Bug Reports
```markdown
## Bug Description
Clear description of what the bug is.

## Steps to Reproduce
1. Go to '...'
2. Click on '....'
3. Scroll down to '....'
4. See error

## Expected Behavior
What you expected to happen.

## Actual Behavior
What actually happened.

## Environment
- OS: [e.g., macOS 12.0]
- Ruby version: [e.g., 3.2.4]
- Rails version: [e.g., 8.0.2]

## Additional Context
Add any other context about the problem here.
```

#### Feature Requests
```markdown
## Feature Description
Clear description of the feature you'd like to see.

## Use Case
Describe the use case and why this feature would be valuable.

## Proposed Solution
Describe how you envision this feature working.

## Alternative Solutions
Describe any alternative solutions you've considered.

## Additional Context
Add any other context or screenshots about the feature request.
```

### 3. Issue Labels and Priorities

#### Labels
- **bug**: Something isn't working
- **feature**: New feature or request
- **enhancement**: Improvement to existing feature
- **trading**: Trading strategy or execution related
- **risk**: Risk management related
- **documentation**: Documentation improvements
- **good first issue**: Good for newcomers
- **help wanted**: Extra attention is needed

#### Priorities
- **0 (No priority)**: Default priority
- **1 (Urgent)**: Critical issues requiring immediate attention
- **2 (High)**: Important issues to address soon
- **3 (Normal)**: Standard priority
- **4 (Low)**: Nice to have improvements

## Code Review Guidelines

### 1. What to Look For

#### Functionality
- Does the code do what it's supposed to do?
- Are edge cases handled properly?
- Is error handling appropriate?
- Are there any obvious bugs?

#### Design and Architecture
- Is the code well-structured?
- Does it follow SOLID principles?
- Is it consistent with existing patterns?
- Are there any code smells?

#### Testing
- Are there sufficient tests?
- Do tests cover edge cases?
- Are tests readable and maintainable?
- Do all tests pass?

#### Security
- Are there any security vulnerabilities?
- Is sensitive data handled properly?
- Are inputs validated and sanitized?
- Are API keys and secrets secure?

#### Performance
- Are there any performance issues?
- Are database queries optimized?
- Is memory usage reasonable?
- Are there any N+1 query problems?

### 2. Review Etiquette

#### Giving Feedback
```markdown
# Good feedback examples:

## Constructive
"Consider using a more descriptive variable name here. `user_positions` would be clearer than `positions`."

## Specific
"This query could cause an N+1 problem. Consider using `includes(:trading_pair)` to eager load the association."

## Educational
"This pattern is great! For future reference, you might also consider using the `delegate` method for simple attribute forwarding."

# Avoid:
- "This is wrong" (not specific)
- "Bad code" (not constructive)
- "Just use X instead" (not educational)
```

#### Receiving Feedback
- Be open to feedback and suggestions
- Ask questions if feedback isn't clear
- Thank reviewers for their time and input
- Address all feedback before requesting re-review

## Development Environment

### 1. Required Tools

#### Core Development
- **Ruby 3.2.4** with RVM or rbenv
- **PostgreSQL 12+** for database
- **Git** for version control
- **Your preferred editor** (VS Code, RubyMine, Vim, etc.)

#### Optional but Recommended
- **Docker** for containerized development
- **Postman** or **curl** for API testing
- **pgAdmin** or **TablePlus** for database management

### 2. Editor Configuration

#### VS Code Settings
```json
{
  "ruby.rubocop.onSave": true,
  "ruby.format": "rubocop",
  "files.trimTrailingWhitespace": true,
  "files.insertFinalNewline": true,
  "editor.rulers": [80, 120]
}
```

#### VS Code Extensions
- Ruby
- Ruby Solargraph
- GitLens
- Bracket Pair Colorizer
- indent-rainbow

### 3. Useful Development Commands

```bash
# Code quality
bin/standardrb --fix          # Fix style issues
bundle exec brakeman          # Security scan
COVERAGE=true bundle exec rspec  # Run tests with coverage

# Database operations
bin/rails db:reset            # Reset database (development)
bin/rails db:seed             # Load seed data
bin/rails db:migrate:status   # Check migration status

# Background jobs
bundle exec good_job start    # Start job worker
bin/rails jobs:work           # Alternative job worker

# Console and debugging
bin/rails console             # Rails console
bin/rails server              # Start web server
tail -f log/development.log   # Watch logs
```

## Release Process

### 1. Version Management

We follow [Semantic Versioning](https://semver.org/):

- **MAJOR.MINOR.PATCH** (e.g., 1.2.3)
- **MAJOR**: Breaking changes
- **MINOR**: New features (backward compatible)
- **PATCH**: Bug fixes (backward compatible)

### 2. Release Checklist

```bash
# 1. Update version
# Edit version in appropriate file

# 2. Update CHANGELOG.md
# Add new version section with changes

# 3. Run full test suite
bundle exec rspec
bin/standardrb
bundle exec brakeman

# 4. Create release branch
git checkout -b release/v1.2.3

# 5. Commit version changes
git add .
git commit -m "chore: bump version to 1.2.3"

# 6. Create and push tag
git tag -a v1.2.3 -m "Release version 1.2.3"
git push upstream v1.2.3

# 7. Create GitHub release
# Use GitHub UI to create release from tag
```

## Getting Help

### 1. Documentation Resources
- **Wiki**: Comprehensive documentation in this wiki
- **README**: Basic setup and usage information
- **Code Comments**: Inline documentation in source code
- **API Docs**: Endpoint documentation in wiki

### 2. Communication Channels
- **GitHub Issues**: Bug reports and feature requests
- **Linear**: Project management and issue tracking
- **Pull Request Comments**: Code-specific discussions
- **Slack** (if configured): Real-time communication

### 3. Common Questions

#### "How do I add a new trading strategy?"
1. Create service class in `app/services/strategy/`
2. Follow existing patterns (see `MultiTimeframeSignal`)
3. Add comprehensive tests
4. Update documentation

#### "How do I add a new background job?"
1. Create job class in `app/jobs/`
2. Inherit from `ApplicationJob`
3. Add cron schedule if needed
4. Add tests and error handling

#### "How do I add a new API endpoint?"
1. Add route to `config/routes.rb`
2. Add controller action
3. Add request specs
4. Update API documentation

---

**Previous**: [Troubleshooting](Troubleshooting) | **Up**: [Home](Home)