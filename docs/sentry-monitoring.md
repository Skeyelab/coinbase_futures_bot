# Sentry Error Tracking and Monitoring

## Overview

The Coinbase Futures Bot implements comprehensive error tracking and performance monitoring using Sentry. This documentation covers the complete implementation including error tracking, performance monitoring, and custom business metrics.

## Configuration

### Basic Setup

Sentry is configured in `config/initializers/sentry.rb` with environment-specific settings:

```ruby
Sentry.init do |config|
  config.dsn = ENV["SENTRY_DSN"]
  config.environment = Rails.env
  config.breadcrumbs_logger = [:active_support_logger, :http_logger]
  
  # Performance monitoring
  config.traces_sample_rate = environment_specific_rate
  config.profiles_sample_rate = environment_specific_rate
  
  # Trading-specific context
  config.before_send = lambda do |event, hint|
    event.tags[:trading_mode] = ENV["PAPER_TRADING_MODE"] == "true" ? "paper" : "live"
    event.tags[:sentiment_enabled] = ENV["SENTIMENT_ENABLE"] == "true" ? "enabled" : "disabled"
    event
  end
end
```

### Environment Variables

```bash
# Required
SENTRY_DSN=your_sentry_dsn_url

# Optional Performance Monitoring
SENTRY_TRACES_SAMPLE_RATE=0.1    # 10% of transactions (production)
SENTRY_PROFILES_SAMPLE_RATE=0.1  # 10% of transactions (production)

# Performance Thresholds
SENTRY_SLOW_QUERY_THRESHOLD=1000      # ms
SENTRY_SLOW_API_THRESHOLD=5000        # ms  
SENTRY_SLOW_TRADING_THRESHOLD=10000   # ms
SENTRY_HIGH_MEMORY_THRESHOLD=1000     # MB

# Application Context
APP_VERSION=1.0.0                     # Release tracking
```

### Sample Rates by Environment

- **Development**: 100% traces and profiles for full debugging
- **Staging**: 50% traces and profiles for thorough testing
- **Production**: 10% traces and profiles for performance monitoring

## Error Tracking Implementation

### 1. Background Jobs (`ApplicationJob`)

All background jobs inherit comprehensive error tracking:

```ruby
class ApplicationJob < ActiveJob::Base
  rescue_from StandardError do |error|
    Sentry.with_scope do |scope|
      scope.set_tag("job_class", self.class.name)
      scope.set_tag("job_id", job_id)
      scope.set_tag("queue_name", queue_name)
      
      scope.set_context("job_arguments", arguments)
      scope.set_context("job_execution", {
        executions: executions,
        enqueued_at: enqueued_at,
        scheduled_at: scheduled_at
      })
      
      Sentry.capture_exception(error)
    end
    
    raise error # Allow normal retry/discard logic
  end
end
```

**Tracked Jobs:**
- `FetchCandlesJob` - Market data collection errors
- `GenerateSignalsJob` - Signal generation failures  
- `DayTradingPositionManagementJob` - Critical position management errors
- `HealthCheckJob` - System health monitoring failures
- `PaperTradingJob` - Trading simulation errors
- All sentiment analysis jobs

### 2. API Controllers (`ApplicationController`)

All API endpoints have comprehensive error tracking:

```ruby
class ApplicationController < ActionController::API
  rescue_from StandardError do |error|
    Sentry.with_scope do |scope|
      scope.set_tag("controller", controller_name)
      scope.set_tag("action", action_name)
      scope.set_tag("request_method", request.method)
      
      scope.set_context("request", {
        url: request.url,
        method: request.method,
        headers: sanitized_headers,
        params: sanitized_params,
        remote_ip: request.remote_ip
      })
      
      Sentry.capture_exception(error)
    end
    
    render json: { error: "Internal server error" }, status: 500
  end
end
```

**Tracked Controllers:**
- `SignalController` - Trading signal API errors
- `PositionsController` - Position management errors
- `HealthController` - Health check endpoint errors
- `SlackController` - Slack webhook errors
- `SentimentController` - Sentiment data API errors

### 3. Service Layer

#### Coinbase API Services

Enhanced error tracking for all Coinbase API interactions:

```ruby
module Coinbase
  class AdvancedTradeClient
    include SentryServiceTracking
    
    def track_api_call(endpoint, operation, &block)
      # Tracks timing, errors, and response context
      # Automatically captures ClientErrors with full context
    end
  end
end
```

**Tracked Services:**
- `AdvancedTradeClient` - Coinbase Advanced Trade API
- `ExchangeClient` - Coinbase Exchange API  
- `CoinbasePositions` - Position management service

#### Market Data Services

WebSocket connection and data processing error tracking:

```ruby
module MarketData
  class CoinbaseFuturesSubscriber
    include SentryServiceTracking
    
    def handle_error(error)
      Sentry.with_scope do |scope|
        scope.set_tag("service", "coinbase_futures_subscriber")
        scope.set_tag("error_type", "websocket_error")
        scope.set_context("websocket", {
          product_ids: @product_ids,
          connection_active: @ws.present?
        })
        
        Sentry.capture_message("WebSocket connection error", level: "error")
      end
    end
  end
end
```

**Tracked Services:**
- `CoinbaseFuturesSubscriber` - Futures market data WebSocket
- `CoinbaseSpotSubscriber` - Spot market data WebSocket
- `CoinbaseRest` - REST market data API

#### External Services

Third-party API error tracking:

```ruby
module Sentiment
  class CryptoPanicClient
    include SentryServiceTracking
    
    # Tracks HTTP errors, JSON parsing errors, and API failures
    # with full request/response context
  end
end
```

**Tracked Services:**
- `CryptoPanicClient` - News sentiment data API
- `SlackNotificationService` - Slack API integration

### 4. ActiveRecord Models

Model validation and operation error tracking via `SentryTrackable` concern:

```ruby
module SentryTrackable
  included do
    after_validation :track_validation_errors, if: :errors_present?
    around_save :track_save_operation
    around_update :track_update_operation
    around_destroy :track_destroy_operation
  end
end
```

**Tracked Models:**
- `Position` - Trading position validation and save errors
- `SignalAlert` - Signal generation and validation errors
- `TradingPair` - Product configuration errors
- `Candle` - Market data validation errors
- `SentimentEvent` - Sentiment data validation errors

### 5. ActionCable Channels

WebSocket channel error tracking:

```ruby
module ApplicationCable
  class Channel < ActionCable::Channel::Base
    rescue_from StandardError do |error|
      Sentry.with_scope do |scope|
        scope.set_tag("channel", self.class.name)
        scope.set_context("channel", {
          params: params.to_h,
          subscriptions: stream_names
        })
        
        Sentry.capture_exception(error)
      end
    end
  end
end
```

**Tracked Channels:**
- `SignalsChannel` - Real-time signal broadcasts

## Performance Monitoring

### 1. Database Query Monitoring

Automatic slow query detection via `SentryDatabaseMonitoring` middleware:

```ruby
class SentryDatabaseMonitoring
  def call(name, started, finished, unique_id, payload)
    duration = (finished - started) * 1000
    
    # Track slow queries (default: >1000ms)
    if duration > @slow_query_threshold
      Sentry.capture_message("Slow database query detected", level: "warning")
    end
  end
end
```

**Monitored Metrics:**
- Query execution time
- Query type (SELECT, INSERT, UPDATE, DELETE)
- Connection pool usage
- Query errors and failures

### 2. External API Performance

API call timing and error tracking:

```ruby
# Automatic tracking in service classes
track_external_api_call("coinbase", "/api/v3/brokerage/accounts", "test_auth") do
  # API call implementation
end
```

**Monitored APIs:**
- Coinbase Advanced Trade API
- Coinbase Exchange API
- CryptoPanic sentiment API
- Slack messaging API

### 3. Trading Operation Performance

Critical trading operation timing:

```ruby
# Track trading operations with business context
track_trading_operation("position_closure", symbol: "BTC-USD", reason: "stop_loss") do
  # Trading logic implementation
end
```

**Monitored Operations:**
- Position opening/closing
- Signal generation
- Order placement
- Risk management operations

### 4. Background Job Performance

Automatic job performance tracking via ActiveSupport notifications:

- Job execution duration
- Long-running job detection (>30 seconds)
- Job queue health monitoring
- Failed job tracking

## Business Metrics and Custom Events

### 1. Trading Events

```ruby
# Signal generation tracking
SentryMonitoringService.track_signal_generated({
  symbol: "BTC-USD",
  side: "LONG",
  confidence: 85,
  strategy_name: "MultiTimeframeSignal"
})

# Position tracking
SentryMonitoringService.track_position_opened(position_data)
SentryMonitoringService.track_position_closed(position_data, "take_profit")
```

### 2. System Health Events

```ruby
# Health check results
SentryMonitoringService.track_health_check(health_data, overall_healthy)

# Critical system events
SentryMonitoringService.track_critical_trading_event(
  "position_force_closure",
  "Emergency position closure due to system shutdown",
  { position_count: 3, reason: "system_shutdown" }
)
```

### 3. Market Data Events

```ruby
# WebSocket connection events
SentryMonitoringService.track_market_data_event("connection_established", {
  service: "coinbase_futures",
  product_ids: ["BTC-USD", "ETH-USD"]
})

# Data processing events  
SentryMonitoringService.track_market_data_event("tick_processed", {
  symbol: "BTC-USD",
  price: 45000.00,
  volume: 1.5
})
```

## Error Organization and Tagging

### Standard Tags

All errors include these standard tags for organization:

- `component`: background_job, api_controller, service, model, websocket
- `error_type`: Specific error classification
- `service`: Service name for external API calls
- `trading_mode`: paper or live
- `critical`: true for critical trading operations

### Custom Context

Rich context data for debugging:

- **Jobs**: Arguments, execution count, queue info
- **API Calls**: Request/response data, timing, authentication status
- **Trading Operations**: Symbol, side, prices, P&L data
- **WebSocket**: Connection status, message types, product IDs

## Monitoring and Alerting

### Critical Error Alerts

Set up Sentry alerts for these critical events:

1. **Trading Operation Failures**
   - Tag: `critical=true`
   - Components: Position management, order placement

2. **API Connectivity Issues**
   - Tag: `error_type=api_client_error`
   - Services: Coinbase APIs, external data feeds

3. **System Health Failures**
   - Tag: `health_check_type=*`
   - Components: Database, background jobs, WebSocket connections

4. **High Error Rates**
   - Threshold: >10 errors per minute
   - Components: Any service or job

### Performance Alerts

Monitor these performance metrics:

1. **Slow Database Queries**
   - Threshold: >1000ms (configurable)
   - Category: `db.query`

2. **Slow API Calls**
   - Threshold: >5000ms (configurable)
   - Category: `api.performance`

3. **Long-Running Jobs**
   - Threshold: >30 seconds
   - Category: `job.performance`

4. **High Memory Usage**
   - Threshold: >1000MB (configurable)
   - Category: `performance.memory`

## Testing Sentry Integration

### Basic Test

```bash
# Test all Sentry functionality
bin/rake sentry:test_all

# Test specific components
bin/rake sentry:test          # Basic error capture
bin/rake sentry:test_job      # Job error tracking
bin/rake sentry:test_service  # Service error tracking
bin/rake sentry:test_performance  # Performance monitoring

# Show current configuration
bin/rake sentry:config
```

### Manual Testing

```ruby
# Test error capture in Rails console
Sentry.capture_message("Test message", level: "info")

# Test with custom context
Sentry.with_scope do |scope|
  scope.set_tag("test", "manual")
  scope.set_context("trading", { symbol: "BTC-USD" })
  Sentry.capture_message("Manual test with context")
end

# Test exception capture
begin
  raise "Test exception"
rescue => e
  Sentry.capture_exception(e)
end
```

### Development Testing

Use the built-in smoke test route:

```bash
# Trigger test error (development only)
curl http://localhost:3000/boom
```

## Best Practices

### 1. Error Context

Always provide rich context for errors:

```ruby
Sentry.with_scope do |scope|
  scope.set_tag("operation", "position_closure")
  scope.set_tag("symbol", "BTC-USD")
  scope.set_context("position", {
    id: position.id,
    side: position.side,
    size: position.size,
    entry_price: position.entry_price
  })
  
  Sentry.capture_exception(error)
end
```

### 2. Breadcrumbs

Use breadcrumbs to track operation flow:

```ruby
Sentry.add_breadcrumb(
  message: "Starting position closure",
  category: "trading",
  level: "info",
  data: { symbol: "BTC-USD", reason: "stop_loss" }
)
```

### 3. Performance Tracking

Track critical operation timing:

```ruby
start_time = Time.current
result = perform_operation
duration = (Time.current - start_time) * 1000

SentryPerformanceService.track_trading_performance(
  "position_closure",
  duration,
  { symbol: "BTC-USD", success: true }
)
```

### 4. Sensitive Data Protection

The configuration automatically filters sensitive data:

- API keys and tokens
- Private keys and secrets
- Personal identifiable information
- Authentication headers

## Monitoring Dashboard

### Key Metrics to Monitor

1. **Error Rates by Component**
   - Background jobs error rate
   - API controller error rate
   - External service error rate

2. **Performance Metrics**
   - Database query performance
   - External API response times
   - Job execution times
   - Memory usage trends

3. **Trading-Specific Metrics**
   - Signal generation success rate
   - Position management errors
   - Market data connection stability
   - Trading operation timing

4. **Business Metrics**
   - Signals generated per hour
   - Positions opened/closed
   - API rate limit hits
   - System health check results

### Alert Configuration

Recommended Sentry alert rules:

1. **Critical Trading Errors**
   - Filter: `tags.critical:true AND tags.component:trading`
   - Threshold: Any occurrence
   - Notification: Immediate

2. **High Error Rate**
   - Filter: `level:error`
   - Threshold: >10 events per minute
   - Notification: Within 5 minutes

3. **Performance Degradation**
   - Filter: `tags.performance:slow_*`
   - Threshold: >5 events per 10 minutes
   - Notification: Within 10 minutes

4. **System Health Issues**
   - Filter: `tags.health_check_type:* AND level:error`
   - Threshold: Any occurrence
   - Notification: Immediate

## Troubleshooting

### Common Issues

1. **High Error Volume**
   - Check for API rate limiting
   - Verify external service availability
   - Review job retry configuration

2. **Missing Context**
   - Ensure concerns are included in services
   - Verify environment variables are set
   - Check breadcrumb implementation

3. **Performance Issues**
   - Review slow query alerts
   - Check external API response times
   - Monitor memory usage trends

### Debug Commands

```bash
# Check Sentry configuration
bin/rake sentry:config

# Test error capture
bin/rake sentry:test

# Monitor job performance
bin/rails console
GoodJob::Job.where(job_class: 'FetchCandlesJob').average(:duration)

# Check recent errors
GoodJob::Job.where.not(error: nil).order(:created_at).last(5)
```

## Integration with Existing Systems

### Slack Notifications

Sentry errors automatically trigger Slack alerts for critical issues:

```ruby
# Critical errors also send Slack notifications
SlackNotificationService.alert(
  "error", 
  "Critical System Error",
  "Sentry error: #{error.message}"
)
```

### Health Checks

Health check results are tracked in Sentry:

```ruby
# Health check job includes Sentry monitoring
def perform
  health_data = gather_health_data
  
  # Publish to Sentry
  ActiveSupport::Notifications.instrument(
    "health_check.completed",
    health_data: health_data,
    overall_healthy: health_data[:overall_health]
  )
end
```

### Background Job Integration

GoodJob dashboard shows errors that are also tracked in Sentry:

- Development: `http://localhost:3000/good_job`
- Sentry provides additional context and aggregation
- Cross-reference job IDs between systems

## Security Considerations

### Data Sanitization

Automatic filtering of sensitive data:

```ruby
# Headers filtered
%w[HTTP_AUTHORIZATION HTTP_COOKIE HTTP_X_API_KEY HTTP_X_AUTH_TOKEN]

# Parameters filtered  
%w[password token secret api_key private_key]

# PII protection
config.send_default_pii = false
```

### Rate Limiting

Sentry has built-in rate limiting to prevent spam:

- Automatic error grouping
- Duplicate event filtering
- Configurable sample rates

## Maintenance

### Regular Tasks

1. **Weekly Review**
   - Check error trends and patterns
   - Review performance metrics
   - Update alert thresholds if needed

2. **Monthly Cleanup**
   - Archive old error data
   - Review and update error grouping rules
   - Optimize sample rates based on usage

3. **Release Updates**
   - Update `APP_VERSION` environment variable
   - Review new error patterns
   - Adjust monitoring for new features

### Configuration Updates

When adding new services or jobs:

1. Include appropriate concerns (`SentryServiceTracking`, `SentryTrackable`)
2. Add specific error context for business logic
3. Update this documentation
4. Test error tracking with `bin/rake sentry:test`

## Examples

### Adding Sentry to New Service

```ruby
class NewTradingService
  include SentryServiceTracking
  
  def execute_trade(symbol, side, size)
    track_trading_operation("execute_trade", symbol: symbol, side: side) do
      # Trading logic here
      result = perform_trade_logic
      
      # Add success breadcrumb
      Sentry.add_breadcrumb(
        message: "Trade executed successfully",
        category: "trading",
        level: "info",
        data: { symbol: symbol, side: side, size: size }
      )
      
      result
    end
  end
end
```

### Adding Sentry to New Job

```ruby
class NewTradingJob < ApplicationJob
  queue_as :trading
  
  def perform(symbol, strategy_params)
    # ApplicationJob automatically handles errors
    # Add specific context with breadcrumbs
    
    Sentry.add_breadcrumb(
      message: "Trading job started",
      category: "job",
      level: "info", 
      data: { symbol: symbol, strategy: strategy_params[:name] }
    )
    
    # Job logic here
  end
end
```

### Adding Sentry to New Controller

```ruby
class NewTradingController < ApplicationController
  # ApplicationController automatically handles errors
  
  def execute_trade
    Sentry.add_breadcrumb(
      message: "Trade execution requested",
      category: "trading",
      level: "info",
      data: { symbol: params[:symbol], side: params[:side] }
    )
    
    # Controller logic here
  end
end
```

This comprehensive Sentry implementation provides full visibility into the trading bot's operations, enabling proactive monitoring and rapid debugging of issues across all system components.