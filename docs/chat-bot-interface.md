# CLI Chat Bot Interface

The FuturesBot includes a comprehensive AI-powered CLI Chat Bot Interface that allows operators to interact with the trading bot through natural language commands. This interface provides full control over trading operations, position monitoring, and system management.

## Overview

The Chat Bot Interface consists of several integrated components:

- **AI-Powered Command Processing**: OpenRouter (Claude 3.5 Sonnet) with ChatGPT fallback
- **Natural Language Understanding**: Advanced pattern matching and context awareness
- **Persistent Memory System**: Database-backed conversation history with profit-focused scoring
- **Trading Control Integration**: Full integration with existing trading services
- **Comprehensive Audit Logging**: Security and compliance tracking for all operations
- **Session Management**: Multi-session support with context retention

## Quick Start

### Launch the Chat Bot

```bash
# Start a new chat session
rails chat_bot:start

# Resume the last active session
rails chat_bot:start --resume

# Resume a specific session
rails chat_bot:start --session <session-id>
```

### Basic Commands

```bash
FuturesBot> help
💡 Available Commands:
• Check positions and PnL
• View active signals
• Get market data for symbols
• System status and health
• Start/resume trading operations
• Stop/pause trading operations
• Emergency stop (close all positions)
• Check position sizing configuration
• View conversation history
• Search past conversations
• List chat sessions
• Show context status
• General trading questions

FuturesBot> show my positions
📊 Positions Summary
Open: 2 (Day: 1, Swing: 1)
Total PnL: $156.78
BTC-PERP: +$98.45 (Day Trading)
ETH-PERP: +$58.33 (Swing Trading)

FuturesBot> quit
👋 Goodbye! Chat session ended.
```

## Command Categories

### 1. Position & PnL Queries

Natural language examples:
- "show my positions"
- "what's my current P&L?"
- "how many positions are open?"
- "display trading summary"

### 2. Signal Analysis

Examples:
- "what signals are active?"
- "show recent trading alerts"
- "any new entry signals?"
- "display signal summary"

### 3. Market Data

Examples:
- "BTC price"
- "show ETH market data"
- "current SOL volume"
- "market conditions for BTC-PERP"

### 4. Trading Control

**⚠️ Security-Sensitive Commands**

Examples:
- "start trading" / "resume trading"
- "stop trading" / "pause trading"
- "emergency stop" / "kill switch"
- "position sizing" / "risk configuration"

### 5. System Status

Examples:
- "system status"
- "health check"
- "bot status"
- "connectivity check"

### 6. Session Management

Examples:
- "history" - Show recent commands
- "search emergency" - Search conversation history
- "sessions" - List all chat sessions
- "context status" - Show memory usage

## Advanced Features

### AI Service Configuration

The chat bot supports dual AI providers for reliability:

```bash
# Environment variables
OPENROUTER_API_KEY=your_openrouter_key     # Primary (Claude 3.5 Sonnet)
OPENAI_API_KEY=your_openai_key             # Fallback (GPT-4)
```

When the primary AI service fails, the system automatically falls back to pattern matching or the secondary provider.

### Session Persistence

All conversations are stored in the database with intelligent scoring:

- **High Impact**: Trading control commands, emergency stops
- **Medium Impact**: Position queries, signal analysis
- **Low Impact**: General queries, help commands

Context is automatically managed to stay within AI token limits while preserving the most relevant conversation history.

### Audit Logging

All commands are comprehensively logged for security and compliance:

```ruby
# Security-sensitive actions generate detailed audit logs
ChatAuditLogger.log_trading_control(
  session_id: session_id,
  action: "emergency_stop",
  user_input: "emergency stop",
  result: result,
  user_context: context
)
```

## Trading Control Operations

### Starting/Stopping Trading

```bash
# Activate trading operations
FuturesBot> start trading
✅ Trading has been activated. The bot will now generate signals and manage positions.

# Pause trading operations
FuturesBot> stop trading
⏸️ Trading has been paused. The bot will stop generating new signals and opening positions.
```

### Emergency Stop

```bash
FuturesBot> emergency stop
🚨 EMERGENCY STOP EXECUTED 🚨

All trading activities have been immediately stopped.
Emergency stop completed successfully.
Positions closed: 2
Orders cancelled: 0
```

The emergency stop feature:
- Immediately disables all trading
- Closes open day trading positions
- Cancels pending orders
- Sets emergency flag in system
- Logs all actions for audit trail

### Position Sizing Configuration

```bash
FuturesBot> position sizing
📊 Position Sizing Configuration:

Equity: $10,000.00
Risk per trade: 2.0%
Max risk per trade: $200.00

To adjust sizing, update environment variables:
- SIGNAL_EQUITY_USD
- RISK_PER_TRADE_PERCENT
```

## Session Management

### Session Commands

```bash
# View recent command history
FuturesBot> history
📜 Recent History (10 messages):
1. [14:23] position_query: show my positions
2. [14:24] signal_query: what signals are active
3. [14:25] trading_control: start trading

# Search conversation history
FuturesBot> search "emergency"
🔍 Search Results for 'emergency' (2 found)
1. [09/24 14:30] [HIGH] emergency stop executed successfully
2. [09/23 16:45] [MEDIUM] emergency procedures reviewed

# List all active sessions
FuturesBot> sessions
💬 Chat Sessions (Current: a1b2c3d4)
→ 1. a1b2c3d4 - Trading Session
    Messages: 15 (8 profitable)
    Last: 09/24 14:25
  2. x9y8z7w6 - Analysis Session
    Messages: 22 (12 profitable)
    Last: 09/23 18:30

# Check context memory status
FuturesBot> context status
🧠 Context Status
Session: a1b2c3d4
Messages: 15 (8 profitable)
Context Length: 2,847 chars (~711 tokens)
Last Activity: 09/24 14:25
```

## Error Handling & Reliability

### AI Service Fallbacks

The system includes multiple layers of reliability:

1. **Primary AI Service**: OpenRouter with Claude 3.5 Sonnet
2. **Fallback AI Service**: OpenAI with GPT-4
3. **Pattern Matching**: Local regex patterns when AI services fail

### Graceful Degradation

When AI services are unavailable, the system falls back to pattern matching:

```ruby
# Fallback patterns for common commands
case input.downcase
when /position|pnl|profit|loss/
  # Process as position query
when /start.*trad|resume.*trad/
  # Process as start trading command
when /emergency.*stop/
  # Process as emergency stop
end
```

### Error Recovery

All errors are logged and tracked:

```bash
FuturesBot> start trading
❌ Processing failed: API service temporarily unavailable

# System automatically attempts fallback processing
# User receives helpful error message
# Full error details logged for debugging
```

## Security Features

### Input Sanitization

All user input is sanitized before processing:

- Strip dangerous characters
- Limit input length (500 characters)
- Escape special characters
- Validate command structure

### Audit Trail

Comprehensive logging for compliance:

- All commands logged with timestamps
- Trading control actions specially flagged
- User context and session information included
- Error tracking and recovery metrics

### Session Security

- Secure session ID generation
- Session isolation between users
- Automatic session timeout
- Memory pruning for efficiency

## Architecture

### Service Layer

```
ChatBotService (Main orchestrator)
├── AiCommandProcessorService (AI API integration)
├── ChatMemoryService (Conversation persistence)
├── ChatAuditLogger (Security & compliance logging)
└── Trading Integration Services
    ├── Position management
    ├── Signal analysis
    ├── Market data access
    └── Risk management
```

### Database Schema

```sql
-- Persistent conversation storage
CREATE TABLE chat_sessions (
  id BIGINT PRIMARY KEY,
  session_id VARCHAR UNIQUE NOT NULL,
  name VARCHAR,
  active BOOLEAN DEFAULT true,
  metadata JSONB,
  created_at TIMESTAMP,
  updated_at TIMESTAMP
);

CREATE TABLE chat_messages (
  id BIGINT PRIMARY KEY,
  chat_session_id BIGINT REFERENCES chat_sessions(id),
  content TEXT NOT NULL,
  message_type VARCHAR NOT NULL, -- 'user', 'bot', 'system'
  profit_impact VARCHAR NOT NULL, -- 'unknown', 'low', 'medium', 'high'
  relevance_score DECIMAL NOT NULL,
  timestamp TIMESTAMP NOT NULL,
  metadata JSONB,
  created_at TIMESTAMP,
  updated_at TIMESTAMP
);
```

## Configuration

### Environment Variables

```bash
# AI Service Configuration
OPENROUTER_API_KEY=your_openrouter_key
OPENAI_API_KEY=your_openai_key

# Trading Configuration
SIGNAL_EQUITY_USD=10000
RISK_PER_TRADE_PERCENT=2

# Security Configuration
SECURITY_MONITORING_ENABLED=true
```

### Database Setup

```bash
# Apply chat bot migrations
bundle exec rails db:migrate
```

## Testing

### Running Tests

```bash
# Core chat bot functionality
bundle exec rspec spec/services/chat_bot_service_spec.rb

# AI service integration
bundle exec rspec spec/services/ai_command_processor_service_spec.rb

# Trading control features
bundle exec rspec spec/services/chat_bot_service_trading_control_spec.rb

# Memory management
bundle exec rspec spec/services/chat_memory_service_spec.rb
```

### Test Coverage

- **ChatBotService**: 24 passing tests
- **AiCommandProcessorService**: 11 passing tests
- **ChatMemoryService**: Comprehensive coverage
- **Trading Control**: Full test suite for security-sensitive operations

## Troubleshooting

### Common Issues

**AI Service Unavailable**
```bash
# Check API keys
echo $OPENROUTER_API_KEY
echo $OPENAI_API_KEY

# Test connectivity
rails console
> AiCommandProcessorService.new.healthy?
```

**Database Connection Issues**
```bash
# Check database connectivity
rails console
> ActiveRecord::Base.connection.active?

# Run migrations if needed
bundle exec rails db:migrate
```

**Session Memory Issues**
```bash
# Check session storage
rails console
> ChatSession.count
> ChatMessage.count

# Clean up old sessions if needed
> ChatSession.where('updated_at < ?', 30.days.ago).destroy_all
```

### Performance Optimization

**Memory Management**
- Sessions automatically pruned at 200 messages
- Context window limited to 4,000 tokens
- Relevance scoring prioritizes profitable conversations

**Response Time**
- AI processing: ~1-2 seconds
- Local commands: <100ms
- Database operations: <50ms

## Integration

### Existing Services

The chat bot integrates with all existing trading services:

- **RealTimeSignalEvaluator**: Signal generation and analysis
- **Position Management**: Real-time position tracking
- **Market Data Services**: Coinbase spot and futures feeds
- **Risk Management**: Position sizing and stop-loss logic

### External APIs

- **OpenRouter**: Primary AI service (Claude 3.5 Sonnet)
- **OpenAI**: Fallback AI service (GPT-4)
- **Coinbase Advanced Trade**: Market data and trading operations

## Future Enhancements

### Planned Features

- **Voice Integration**: Text-to-speech and speech-to-text
- **Mobile App Support**: REST API endpoints
- **Advanced Analytics**: Pattern recognition in usage
- **Multi-Language Support**: Internationalization

### Integration Opportunities

- **Slack Integration**: Direct bot commands in Slack
- **Discord Integration**: Community trading commands
- **Web Interface**: Browser-based chat
- **API Gateway**: RESTful API for external tools

---

For additional information, see:
- [Services Guide](../wiki/Services-Guide.md)
- [API Reference](../wiki/API-Reference.md)
- [Architecture Overview](../wiki/Architecture.md)
- [Testing Guide](../wiki/Testing-Guide.md)