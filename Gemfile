source "https://rubygems.org"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 8.0.2"
# Use postgresql as the database for Active Record
gem "pg", "~> 1.6"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"
# Use Redis adapter to run Action Cable in production
# gem "redis", ">= 4.0.1"

# Use Kredis to get higher-level data types in Redis [https://github.com/rails/kredis]
# gem "kredis"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
# gem "bcrypt", "~> 3.1.7"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[windows jruby]

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Use Rack CORS for handling Cross-Origin Resource Sharing (CORS), making cross-origin Ajax possible
# gem "rack-cors"

# HTTP client for Coinbase REST
gem "faraday", "~> 2.11"

# WebSocket client for market data subscriptions
gem "websocket-client-simple", "~> 0.8"

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[mri windows], require: "debug/prelude"

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # StandardRB for Ruby code formatting and linting [https://github.com/standardrb/standard]
  gem "standard", ">= 1.35.1", require: false

  # Load environment variables from .env files in development and test
  gem "dotenv-rails"

  # RSpec for testing
  gem "parallel_tests", group: :development, require: false
  gem "rspec-rails", "~> 8.0"
end

group :test do
  gem "climate_control"
  # Codecov integration removed - no external uploads needed
  gem "factory_bot_rails", "~> 6.5"
  gem "rails-controller-testing"
  gem "vcr"
  gem "webmock"

  # Test profiling and optimization
  gem "test-prof", "~> 1.2", require: false

  # JUnit XML output for CI systems
  gem "rspec_junit_formatter", "~> 0.6"

  # Code coverage analysis and reporting
  gem "simplecov", "~> 0.22", require: false
  gem "simplecov-cobertura", "~> 3.1", require: false
  gem "simplecov-json", "~> 0.2", require: false
end

gem "good_job", "~> 4.11"
gem "sentry-rails"
gem "sentry-ruby"

# JWT for Coinbase App (Advanced Trade) ES256 authentication
gem "jwt", "~> 3.1"

# Slack integration for notifications and bot control
gem "slack-ruby-client", "~> 2.4"

# Pagination for API endpoints
gem "kaminari", "~> 1.2"
