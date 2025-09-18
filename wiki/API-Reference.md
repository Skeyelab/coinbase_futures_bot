# API Reference

## Overview

The coinbase_futures_bot provides a comprehensive REST API for accessing trading signals, position data, sentiment analysis, and system health information. The API is built with Rails 8.0 and follows RESTful conventions with JSON responses.

## Base URL

```
http://localhost:3000  # Development
https://your-domain.com # Production
```

## Authentication

Most endpoints require API key authentication:

```bash
# Header-based authentication (recommended)
curl -H "X-API-Key: your-api-key" https://api.example.com/signals

# Query parameter authentication
curl "https://api.example.com/signals?api_key=your-api-key"
```

**Configuration**:
```bash
SIGNALS_API_KEY=your_secure_api_key
```

## API Endpoints

### 1. Health & Status Endpoints

#### System Health Check
**GET** `/up`

Basic Rails health check endpoint.

**Response**:
```json
{
  "status": "ok"
}
```

**Example**:
```bash
curl http://localhost:3000/up
```

#### Extended Health Check
**GET** `/health`

Comprehensive system health with database connection pool information.

**Response**:
```json
{
  "status": "healthy",
  "database": {
    "status": "connected",
    "pool_size": 5,
    "connections_in_use": 2
  },
  "timestamp": "2025-01-18T10:30:00Z"
}
```

**Example**:
```bash
curl http://localhost:3000/health
```

#### Signal System Health
**GET** `/signals/health`

Health check specifically for the real-time signal system.

**Response**:
```json
{
  "status": "healthy",
  "last_signal_timestamp": "2025-01-18T10:25:00Z",
  "recent_signals_count": 12,
  "active_signals_count": 5,
  "timestamp": "2025-01-18T10:30:00Z"
}
```

**Example**:
```bash
curl http://localhost:3000/signals/health
```

### 2. Trading Signals API

#### List Active Signals
**GET** `/signals`

Retrieve all active trading signals with filtering and pagination.

**Authentication**: Required

**Query Parameters**:
- `symbol` (string, optional): Filter by trading symbol (e.g., "BTC-USD")
- `strategy` (string, optional): Filter by strategy name
- `side` (string, optional): Filter by signal side ("long" or "short")
- `signal_type` (string, optional): Filter by signal type
- `min_confidence` (number, optional): Minimum confidence threshold (0-100)
- `max_confidence` (number, optional): Maximum confidence threshold (0-100)
- `page` (integer, optional): Page number for pagination (default: 1)
- `per_page` (integer, optional): Results per page (default: 50, max: 100)

**Response**:
```json
{
  "signals": [
    {
      "id": 123,
      "symbol": "BTC-USD",
      "side": "long",
      "signal_type": "entry",
      "strategy_name": "multi_timeframe_signal",
      "confidence": 85.5,
      "entry_price": 45000.00,
      "stop_loss": 44500.00,
      "take_profit": 45800.00,
      "quantity": 2,
      "timeframe": "5m",
      "alert_status": "active",
      "alert_timestamp": "2025-01-18T10:25:00Z",
      "expires_at": "2025-01-18T11:25:00Z",
      "metadata": {
        "ema_trend": "bullish",
        "sentiment_z_score": 1.2
      }
    }
  ],
  "meta": {
    "total_count": 15,
    "current_page": 1,
    "per_page": 50,
    "total_pages": 1
  }
}
```

**Examples**:
```bash
# Get all active signals
curl -H "X-API-Key: your-key" http://localhost:3000/signals

# Filter by symbol and minimum confidence
curl -H "X-API-Key: your-key" \
  "http://localhost:3000/signals?symbol=BTC-USD&min_confidence=80"

# Get only long signals with pagination
curl -H "X-API-Key: your-key" \
  "http://localhost:3000/signals?side=long&page=1&per_page=10"
```

#### Get Specific Signal
**GET** `/signals/:id`

Retrieve detailed information about a specific signal.

**Authentication**: Required

**Response**:
```json
{
  "id": 123,
  "symbol": "BTC-USD",
  "side": "long",
  "signal_type": "entry",
  "strategy_name": "multi_timeframe_signal",
  "confidence": 85.5,
  "entry_price": 45000.00,
  "stop_loss": 44500.00,
  "take_profit": 45800.00,
  "quantity": 2,
  "timeframe": "5m",
  "alert_status": "active",
  "alert_timestamp": "2025-01-18T10:25:00Z",
  "expires_at": "2025-01-18T11:25:00Z",
  "triggered_at": null,
  "metadata": {
    "ema_trend": "bullish",
    "sentiment_z_score": 1.2,
    "volatility": 0.025
  },
  "strategy_data": {
    "ema_1h_short": 21,
    "ema_1h_long": 50,
    "ema_15m": 21,
    "current_trend": "bullish"
  }
}
```

**Example**:
```bash
curl -H "X-API-Key: your-key" http://localhost:3000/signals/123
```

#### Trigger Signal Evaluation
**POST** `/signals/evaluate`

Manually trigger real-time signal evaluation for specific symbols or all enabled pairs.

**Authentication**: Required

**Request Body**:
```json
{
  "symbols": ["BTC-USD", "ETH-USD"],  // Optional: specific symbols
  "force": true,                      // Optional: force evaluation even if recently done
  "strategy": "multi_timeframe_signal" // Optional: specific strategy
}
```

**Response**:
```json
{
  "status": "success",
  "message": "Signal evaluation triggered",
  "symbols_evaluated": ["BTC-USD", "ETH-USD"],
  "signals_generated": 2,
  "evaluation_id": "eval_abc123",
  "timestamp": "2025-01-18T10:30:00Z"
}
```

**Examples**:
```bash
# Trigger evaluation for all enabled pairs
curl -X POST -H "X-API-Key: your-key" \
  -H "Content-Type: application/json" \
  http://localhost:3000/signals/evaluate

# Trigger evaluation for specific symbols
curl -X POST -H "X-API-Key: your-key" \
  -H "Content-Type: application/json" \
  -d '{"symbols": ["BTC-USD"], "force": true}' \
  http://localhost:3000/signals/evaluate
```

#### Get High-Confidence Signals
**GET** `/signals/high_confidence`

Retrieve signals with confidence above a threshold (default: 80%).

**Authentication**: Required

**Query Parameters**:
- `threshold` (number, optional): Confidence threshold (default: 80)
- `limit` (integer, optional): Maximum results (default: 20)

**Response**:
```json
{
  "signals": [
    {
      "id": 124,
      "symbol": "BTC-USD",
      "side": "long",
      "confidence": 92.3,
      "entry_price": 45100.00,
      "alert_timestamp": "2025-01-18T10:28:00Z"
    }
  ],
  "threshold": 80,
  "count": 1
}
```

**Example**:
```bash
curl -H "X-API-Key: your-key" \
  "http://localhost:3000/signals/high_confidence?threshold=85"
```

#### Get Recent Signals
**GET** `/signals/recent`

Retrieve signals from the last N hours.

**Authentication**: Required

**Query Parameters**:
- `hours` (integer, optional): Hours to look back (default: 1)
- `limit` (integer, optional): Maximum results (default: 50)

**Response**:
```json
{
  "signals": [
    {
      "id": 125,
      "symbol": "ETH-USD",
      "side": "short",
      "confidence": 78.5,
      "alert_timestamp": "2025-01-18T10:15:00Z"
    }
  ],
  "hours_back": 1,
  "count": 1
}
```

#### Get Signal Statistics
**GET** `/signals/stats`

Retrieve signal performance statistics.

**Authentication**: Required

**Query Parameters**:
- `period` (string, optional): Time period ("1h", "24h", "7d", default: "24h")

**Response**:
```json
{
  "period": "24h",
  "total_signals": 45,
  "high_confidence_signals": 12,
  "triggered_signals": 8,
  "expired_signals": 15,
  "average_confidence": 76.8,
  "by_symbol": {
    "BTC-USD": 28,
    "ETH-USD": 17
  },
  "by_side": {
    "long": 23,
    "short": 22
  },
  "timestamp": "2025-01-18T10:30:00Z"
}
```

#### Trigger Specific Signal
**POST** `/signals/:id/trigger`

Mark a signal as triggered (used when signal is acted upon).

**Authentication**: Required

**Request Body**:
```json
{
  "execution_price": 45050.00,  // Optional: actual execution price
  "notes": "Executed via manual order"  // Optional: execution notes
}
```

**Response**:
```json
{
  "status": "success",
  "message": "Signal marked as triggered",
  "signal_id": 123,
  "triggered_at": "2025-01-18T10:30:00Z"
}
```

#### Cancel Signal
**POST** `/signals/:id/cancel`

Cancel an active signal.

**Authentication**: Required

**Request Body**:
```json
{
  "reason": "Market conditions changed"  // Optional: cancellation reason
}
```

**Response**:
```json
{
  "status": "success",
  "message": "Signal cancelled",
  "signal_id": 123,
  "cancelled_at": "2025-01-18T10:30:00Z"
}
```

### 3. Position Management API

#### List Positions
**GET** `/api/positions`

Retrieve active trading positions.

**Query Parameters**:
- `type` (string, optional): Position type ("day_trading" or "swing_trading")
- `product_id` (string, optional): Filter by trading pair
- `side` (string, optional): Filter by position side ("long" or "short")
- `limit` (integer, optional): Maximum results

**Response**:
```json
{
  "positions": [
    {
      "id": 456,
      "product_id": "BTC-USD",
      "side": "long",
      "size": 2.0,
      "entry_price": 45000.00,
      "current_price": 45200.00,
      "unrealized_pnl": 400.00,
      "entry_time": "2025-01-18T09:30:00Z",
      "day_trading": true,
      "status": "open",
      "take_profit": 45800.00,
      "stop_loss": 44500.00
    }
  ],
  "summary": {
    "day_trading_count": 3,
    "swing_trading_count": 1,
    "total_count": 4
  },
  "timestamp": "2025-01-18T10:30:00Z"
}
```

**Examples**:
```bash
# Get all open positions
curl http://localhost:3000/api/positions

# Get only day trading positions
curl "http://localhost:3000/api/positions?type=day_trading"

# Get positions for specific symbol
curl "http://localhost:3000/api/positions?product_id=BTC-USD"
```

#### Position Summary
**GET** `/api/positions/summary`

Get aggregated position summary and P&L information.

**Response**:
```json
{
  "total_positions": 4,
  "day_trading_positions": 3,
  "swing_positions": 1,
  "total_unrealized_pnl": 1250.00,
  "total_realized_pnl_today": 850.00,
  "largest_position": {
    "product_id": "BTC-USD",
    "size": 5.0,
    "unrealized_pnl": 800.00
  },
  "by_symbol": {
    "BTC-USD": {
      "positions": 2,
      "total_size": 7.0,
      "unrealized_pnl": 950.00
    },
    "ETH-USD": {
      "positions": 2,
      "total_size": 15.0,
      "unrealized_pnl": 300.00
    }
  },
  "timestamp": "2025-01-18T10:30:00Z"
}
```

#### Position Exposure
**GET** `/api/positions/exposure`

Get position exposure and risk metrics.

**Response**:
```json
{
  "total_exposure_usd": 225000.00,
  "day_trading_exposure": 135000.00,
  "swing_exposure": 90000.00,
  "leverage": 2.5,
  "margin_used": 90000.00,
  "available_margin": 60000.00,
  "risk_metrics": {
    "portfolio_var": 5250.00,
    "max_drawdown_risk": 0.035,
    "concentration_risk": 0.42
  },
  "by_asset": {
    "BTC": {
      "exposure_usd": 135000.00,
      "percentage": 60.0
    },
    "ETH": {
      "exposure_usd": 90000.00,
      "percentage": 40.0
    }
  },
  "timestamp": "2025-01-18T10:30:00Z"
}
```

### 4. Sentiment Analysis API

#### Get Sentiment Aggregates
**GET** `/sentiment/aggregates`

Retrieve sentiment analysis data for trading symbols.

**Query Parameters**:
- `symbol` (string, optional): Trading symbol (default: "BTC-USD")
- `window` (string, optional): Time window ("5m", "15m", "1h", default: "15m")
- `limit` (integer, optional): Maximum results (default: 20, max: 200)

**Response**:
```json
{
  "symbol": "BTC-USD",
  "window": "15m",
  "count": 20,
  "data": [
    {
      "window_end_at": "2025-01-18T10:30:00Z",
      "count": 8,
      "avg_score": 0.65,
      "weighted_score": 0.72,
      "z_score": 1.8
    },
    {
      "window_end_at": "2025-01-18T10:15:00Z",
      "count": 12,
      "avg_score": 0.45,
      "weighted_score": 0.52,
      "z_score": 0.9
    }
  ]
}
```

**Examples**:
```bash
# Get BTC sentiment for 15m windows
curl "http://localhost:3000/sentiment/aggregates?symbol=BTC-USD&window=15m"

# Get ETH sentiment for 1h windows
curl "http://localhost:3000/sentiment/aggregates?symbol=ETH-USD&window=1h&limit=10"
```

### 5. Position Management UI Endpoints

#### Position Dashboard
**GET** `/positions`

Web interface for position management (returns HTML).

#### Create Position
**POST** `/positions`

Create a new position (form-based).

#### Edit Position
**GET** `/positions/:product_id/edit`

Edit position form (returns HTML).

#### Update Position
**PATCH** `/positions/:product_id`

Update position parameters.

#### Close Position
**POST** `/positions/:product_id/close`

Close a specific position.

#### Increase Position
**POST** `/positions/:product_id/increase`

Increase position size.

### 6. Slack Integration Endpoints

#### Slack Commands
**POST** `/slack/commands`

Handle Slack slash commands.

**Request Body** (form-encoded):
```
command=/bot-status
text=
user_id=U1234567
channel_id=C1234567
```

**Response**:
```json
{
  "text": "🟢 Bot Status: Active\n📊 Positions: 4 open\n💰 P&L Today: +$850.00",
  "response_type": "ephemeral"
}
```

#### Slack Events
**POST** `/slack/events`

Handle Slack events and interactions.

#### Slack Health
**GET** `/slack/health`

Health check for Slack integration.

## Error Handling

The API uses standard HTTP status codes and returns JSON error responses:

### Error Response Format

```json
{
  "error": "Error description",
  "code": "ERROR_CODE",
  "details": {
    "field": "Additional error details"
  },
  "timestamp": "2025-01-18T10:30:00Z"
}
```

### Common HTTP Status Codes

- **200 OK**: Successful request
- **201 Created**: Resource created successfully
- **400 Bad Request**: Invalid request parameters
- **401 Unauthorized**: Missing or invalid API key
- **404 Not Found**: Resource not found
- **422 Unprocessable Entity**: Validation errors
- **429 Too Many Requests**: Rate limit exceeded
- **500 Internal Server Error**: Server error

### Example Error Responses

#### Unauthorized Access
```json
{
  "error": "Unauthorized",
  "code": "UNAUTHORIZED",
  "timestamp": "2025-01-18T10:30:00Z"
}
```

#### Resource Not Found
```json
{
  "error": "Signal not found",
  "code": "NOT_FOUND",
  "details": {
    "signal_id": 999
  },
  "timestamp": "2025-01-18T10:30:00Z"
}
```

#### Validation Error
```json
{
  "error": "Invalid parameters",
  "code": "VALIDATION_ERROR",
  "details": {
    "confidence": "must be between 0 and 100",
    "symbol": "is required"
  },
  "timestamp": "2025-01-18T10:30:00Z"
}
```

## Rate Limiting

The API implements rate limiting to prevent abuse:

- **Default Limit**: 100 requests per minute per API key
- **Burst Limit**: 20 requests per 10 seconds
- **Headers**: Rate limit information is returned in response headers

**Rate Limit Headers**:
```
X-RateLimit-Limit: 100
X-RateLimit-Remaining: 95
X-RateLimit-Reset: 1642507800
```

## CORS Support

The API includes CORS headers for browser-based access:

```
Access-Control-Allow-Origin: *
Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS
Access-Control-Allow-Headers: Content-Type, X-API-Key
```

## WebSocket Integration

For real-time updates, the API also supports WebSocket connections:

```javascript
// Connect to real-time signals
const ws = new WebSocket('ws://localhost:3000/cable');
ws.send(JSON.stringify({
  command: 'subscribe',
  identifier: JSON.stringify({
    channel: 'SignalsChannel',
    api_key: 'your-api-key'
  })
}));
```

## SDK Examples

### JavaScript/Node.js

```javascript
class CoinbaseFuturesBotAPI {
  constructor(apiKey, baseUrl = 'http://localhost:3000') {
    this.apiKey = apiKey;
    this.baseUrl = baseUrl;
  }

  async getSignals(filters = {}) {
    const params = new URLSearchParams(filters);
    const response = await fetch(`${this.baseUrl}/signals?${params}`, {
      headers: { 'X-API-Key': this.apiKey }
    });
    return response.json();
  }

  async triggerEvaluation(symbols = []) {
    const response = await fetch(`${this.baseUrl}/signals/evaluate`, {
      method: 'POST',
      headers: {
        'X-API-Key': this.apiKey,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({ symbols })
    });
    return response.json();
  }
}

// Usage
const api = new CoinbaseFuturesBotAPI('your-api-key');
const signals = await api.getSignals({ symbol: 'BTC-USD', min_confidence: 80 });
```

### Python

```python
import requests

class CoinbaseFuturesBotAPI:
    def __init__(self, api_key, base_url='http://localhost:3000'):
        self.api_key = api_key
        self.base_url = base_url
        self.headers = {'X-API-Key': api_key}

    def get_signals(self, **filters):
        response = requests.get(
            f'{self.base_url}/signals',
            headers=self.headers,
            params=filters
        )
        return response.json()

    def get_positions(self, position_type=None):
        params = {'type': position_type} if position_type else {}
        response = requests.get(
            f'{self.base_url}/api/positions',
            params=params
        )
        return response.json()

# Usage
api = CoinbaseFuturesBotAPI('your-api-key')
signals = api.get_signals(symbol='BTC-USD', min_confidence=80)
positions = api.get_positions(position_type='day_trading')
```

### cURL Examples

```bash
#!/bin/bash

API_KEY="your-api-key"
BASE_URL="http://localhost:3000"

# Get high-confidence BTC signals
curl -H "X-API-Key: $API_KEY" \
  "$BASE_URL/signals?symbol=BTC-USD&min_confidence=85"

# Trigger signal evaluation
curl -X POST -H "X-API-Key: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"symbols": ["BTC-USD", "ETH-USD"]}' \
  "$BASE_URL/signals/evaluate"

# Get position summary
curl "$BASE_URL/api/positions/summary"

# Get sentiment data
curl "$BASE_URL/sentiment/aggregates?symbol=BTC-USD&window=1h"
```

---

**Next**: [Database Schema](Database-Schema) | **Previous**: [Background Jobs](Background-Jobs) | **Up**: [Home](Home)