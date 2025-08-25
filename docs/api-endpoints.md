# API Endpoints Documentation

## Overview

The coinbase_futures_bot provides a Rails API for position management and sentiment data access. The API is designed primarily for administrative use and monitoring, with most trading operations handled through background jobs.

## Base URL

```
Development: http://localhost:3000
Production: https://your-domain.com
```

## Authentication

Currently, the API endpoints are unauthenticated. For production deployments, consider adding authentication middleware for security.

## Health Check

### GET /up

Health check endpoint for monitoring and load balancers.

**Description:** Returns 200 if the application boots with no exceptions, otherwise 500.

**Response:**
```json
HTTP 200 OK
{
  "status": "ok"
}
```

**Example:**
```bash
curl -X GET http://localhost:3000/up
```

**Use Cases:**
- Load balancer health checks
- Uptime monitoring
- Application deployment verification

## Position Management

The positions endpoints provide a web interface for managing trading positions. These are primarily for manual oversight and debugging.

### GET /positions

**Description:** List all positions with filtering options.

**Parameters:**
- None currently implemented

**Response:**
```html
<!-- HTML view for position listing -->
```

**Example:**
```bash
curl -X GET http://localhost:3000/positions
```

### GET /positions/new

**Description:** Form for creating a new position.

**Response:**
```html
<!-- HTML form for position creation -->
```

### POST /positions

**Description:** Create a new position.

**Parameters:**
- `product_id` (required) - Trading pair identifier
- Position-specific parameters (implementation dependent)

**Example:**
```bash
curl -X POST http://localhost:3000/positions \
  -H "Content-Type: application/json" \
  -d '{"product_id": "BTC-USD", ...}'
```

### GET /positions/:product_id/edit

**Description:** Form for editing an existing position.

**Parameters:**
- `product_id` (path) - Trading pair identifier

### PATCH/PUT /positions/:product_id

**Description:** Update an existing position.

**Parameters:**
- `product_id` (path) - Trading pair identifier
- Position update parameters

### POST /positions/:product_id/close

**Description:** Close an existing position.

**Parameters:**
- `product_id` (path) - Trading pair identifier

**Example:**
```bash
curl -X POST http://localhost:3000/positions/BTC-USD/close
```

### POST /positions/:product_id/increase

**Description:** Increase the size of an existing position.

**Parameters:**
- `product_id` (path) - Trading pair identifier
- Size increase parameters

**Example:**
```bash
curl -X POST http://localhost:3000/positions/BTC-USD/increase
```

## Sentiment Analysis

### GET /sentiment/aggregates

**Description:** Retrieve sentiment aggregates for monitoring and analysis.

**Parameters:**
- `symbol` (optional) - Trading pair symbol (e.g., "BTC-USD")
- `window` (optional) - Time window (5m, 15m, 1h)
- `limit` (optional) - Number of records to return (default: 20)

**Response:**
```json
[
  {
    "id": 123,
    "symbol": "BTC-USD",
    "window": "15m",
    "window_end_at": "2025-01-14T10:15:00.000Z",
    "count": 5,
    "avg_score": 0.2500,
    "weighted_score": 0.2800,
    "z_score": 1.2500,
    "meta": {
      "window_start": "2025-01-14T10:00:00.000Z"
    },
    "created_at": "2025-01-14T10:16:00.000Z",
    "updated_at": "2025-01-14T10:16:00.000Z"
  }
]
```

**Example Requests:**

```bash
# Get latest BTC sentiment aggregates
curl -X GET "http://localhost:3000/sentiment/aggregates?symbol=BTC-USD&limit=10"

# Get 15-minute window aggregates
curl -X GET "http://localhost:3000/sentiment/aggregates?window=15m&limit=20"

# Get recent aggregates for monitoring
curl -X GET "http://localhost:3000/sentiment/aggregates?limit=5" | jq
```

**Response Fields:**
- `symbol` - Trading pair symbol
- `window` - Time window duration
- `window_end_at` - End timestamp of the aggregation window
- `count` - Number of sentiment events in the window
- `avg_score` - Average sentiment score (-1.0 to 1.0)
- `weighted_score` - Confidence-weighted sentiment score
- `z_score` - Normalized z-score for statistical analysis
- `meta` - Additional metadata including window start time

**Use Cases:**
- Real-time sentiment monitoring
- Strategy backtesting with sentiment data
- Debugging sentiment analysis pipeline
- External system integration

## Development-Only Endpoints

### GET /good_job (Development Only)

**Description:** GoodJob dashboard for monitoring background jobs.

**Access:** Only available in development environment

**Features:**
- Job queue monitoring
- Job execution history
- Performance metrics
- Job retry management

**Example:**
```
http://localhost:3000/good_job
```

### GET /boom (Development Only)

**Description:** Sentry smoke test endpoint that deliberately raises an exception.

**Access:** Only available in development environment

**Example:**
```bash
curl -X GET http://localhost:3000/boom
# Triggers: RuntimeError: "Sentry smoke test"
```

## Error Handling

### Standard Error Responses

**400 Bad Request:**
```json
{
  "error": "Bad Request",
  "message": "Invalid parameters"
}
```

**404 Not Found:**
```json
{
  "error": "Not Found",
  "message": "Resource not found"
}
```

**500 Internal Server Error:**
```json
{
  "error": "Internal Server Error",
  "message": "An unexpected error occurred"
}
```

## Rate Limiting

Currently, no rate limiting is implemented. Consider adding rate limiting for production deployments:

```ruby
# Example rate limiting with rack-attack
Rack::Attack.throttle('api/ip', limit: 100, period: 1.hour) do |req|
  req.ip if req.path.start_with?('/api/')
end
```

## CORS Configuration

CORS is configured in `config/initializers/cors.rb`. Adjust for production requirements:

```ruby
Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins 'localhost:3000', 'your-frontend-domain.com'
    resource '*', headers: :any, methods: [:get, :post, :patch, :put, :delete]
  end
end
```

## API Versioning

Currently, no API versioning is implemented. For future API evolution, consider:

```ruby
# Example versioned routes
namespace :api do
  namespace :v1 do
    resources :positions
    get 'sentiment/aggregates', to: 'sentiment#aggregates'
  end
end
```

## Monitoring and Observability

### Health Check Integration

The `/up` endpoint can be integrated with monitoring systems:

```bash
# Kubernetes liveness probe
livenessProbe:
  httpGet:
    path: /up
    port: 3000
  initialDelaySeconds: 30
  periodSeconds: 10

# Load balancer health check
curl -f http://localhost:3000/up || exit 1
```

### Logging

API requests are logged through Rails standard logging. Configure log levels in `config/environments/`:

```ruby
# Development
config.log_level = :debug

# Production
config.log_level = :info
```

### Metrics

Consider adding metrics collection for production:

```ruby
# Example with Prometheus
get '/metrics' do
  # Export application metrics
end
```

## Security Considerations

### Authentication

For production deployment, implement authentication:

```ruby
# Example with JWT
before_action :authenticate_request

private

def authenticate_request
  @current_user = AuthorizeApiRequest.call(request.headers).result
  render json: { error: 'Not Authorized' }, status: 401 unless @current_user
end
```

### Input Validation

Implement proper parameter validation:

```ruby
# Example strong parameters
def sentiment_params
  params.permit(:symbol, :window, :limit)
end
```

### HTTPS

Ensure HTTPS in production:

```ruby
# config/environments/production.rb
config.force_ssl = true
```

## Testing

API endpoints should be tested using RSpec request specs:

```ruby
# spec/requests/sentiment_controller_spec.rb
RSpec.describe "Sentiment API", type: :request do
  describe "GET /sentiment/aggregates" do
    it "returns sentiment aggregates" do
      get "/sentiment/aggregates"
      expect(response).to have_http_status(200)
      expect(JSON.parse(response.body)).to be_an(Array)
    end
  end
end
```

## Future Enhancements

### API Improvements
- Add authentication and authorization
- Implement proper API versioning
- Add rate limiting and throttling
- Enhance error handling and validation

### New Endpoints
- Trading signal endpoints for external access
- Market data API for real-time data access
- Strategy configuration endpoints
- Performance metrics API

### Integration Features
- WebSocket API for real-time updates
- Webhook notifications for position changes
- REST API for strategy parameters
- External system integrations
