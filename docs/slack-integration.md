# Slack Integration Documentation

## Overview

The Coinbase Futures Bot includes comprehensive Slack integration for real-time notifications, bot control, and monitoring. This integration enables traders to interact with the bot, receive alerts, and monitor performance directly through Slack.

## Features

### 🔔 Real-Time Notifications

- **Trading Signals**: Automatically posted when new signals are generated
- **Position Updates**: Notifications for position openings, closures, and updates
- **PnL Reports**: Regular profit/loss updates and summaries
- **Health Alerts**: System health monitoring and issue alerts
- **Error Notifications**: Critical error alerts with detailed information

### 🎮 Bot Control Commands

The bot responds to the following slash commands:

- `/bot-status` - Show current bot status and statistics
- `/bot-pause` - Pause trading operations (stop new signals)
- `/bot-resume` - Resume trading operations
- `/bot-positions [filter]` - Show current positions (filter: open, closed, symbol)
- `/bot-pnl [period]` - Show PnL report (period: today, week, month)
- `/bot-health` - Show system health status
- `/bot-stop` - 🚨 Emergency stop all trading activities
- `/bot-help` - Show help message with all commands

### 📊 Monitoring Dashboard

- **Health Checks**: Automated system health monitoring
- **Performance Metrics**: Real-time trading performance data
- **Market Conditions**: Alert on unusual market conditions
- **Position Management**: Track position lifecycles and risk metrics

## Setup

### 1. Slack App Configuration

Create a new Slack app at [api.slack.com](https://api.slack.com/apps) with the following configuration:

#### Bot Token Scopes (OAuth & Permissions)
```
channels:read     - Read public channel information
chat:write        - Send messages
commands          - Receive slash commands
im:read          - Read direct messages
im:write         - Send direct messages
users:read       - Read user profile information
```

#### Event Subscriptions
- **Request URL**: `https://your-domain.com/slack/events`
- **Subscribe to bot events**:
  - `message.im` - Direct messages to bot
  - `app_mention` - When bot is mentioned in channels

#### Slash Commands
Create the following slash commands pointing to `https://your-domain.com/slack/commands`:

| Command | Description | Usage Hint |
|---------|-------------|------------|
| `/bot-status` | Show bot status | Get current trading status and statistics |
| `/bot-pause` | Pause trading | Stop new signal generation |
| `/bot-resume` | Resume trading | Resume normal operations |
| `/bot-positions` | Show positions | [open\|closed\|symbol] |
| `/bot-pnl` | Show PnL report | [today\|week\|month] |
| `/bot-health` | System health | Show health check results |
| `/bot-stop` | Emergency stop | ⚠️ Immediately stop all trading |
| `/bot-help` | Show help | List all available commands |

### 2. Environment Configuration

Add the following environment variables to your `.env` file:

```bash
# Enable Slack integration
SLACK_ENABLED=true

# Slack credentials (from your app's settings)
SLACK_BOT_TOKEN=xoxb-your-bot-token-here
SLACK_SIGNING_SECRET=your-signing-secret-here

# Channel configuration
SLACK_SIGNALS_CHANNEL=#trading-signals
SLACK_POSITIONS_CHANNEL=#trading-positions
SLACK_STATUS_CHANNEL=#bot-status
SLACK_ALERTS_CHANNEL=#trading-alerts

# Security: authorized users (comma-separated Slack user IDs)
SLACK_AUTHORIZED_USERS=U1234567890,U0987654321
```

### 3. Channel Setup

Create the following channels in your Slack workspace:

- `#trading-signals` - Trading signal notifications
- `#trading-positions` - Position update notifications
- `#bot-status` - Bot status and health updates
- `#trading-alerts` - Error alerts and critical notifications

Invite your bot to all channels where it needs to post messages.

### 4. Install Dependencies

The Slack integration uses the `slack-ruby-client` gem, which is already included in the Gemfile:

```bash
bundle install
```

## Usage

### Notification Types

#### Trading Signal Notifications
```
🎯 New Trading Signal: BTC-USD
Symbol: BTC-USD        Side: LONG
Price: $50,000.00      Quantity: 0.1
Take Profit: $52,000   Stop Loss: $48,000
Confidence: 75%        Timestamp: 2025-01-15 14:30:00 UTC
```

#### Position Update Notifications
```
🟢 Position Opened: ETH-USD
Symbol: ETH-USD        Side: LONG
Size: 1.0              Entry Price: $3,000.00
```

#### PnL Update Notifications
```
📈 PnL Update
Total PnL: $500.00     Daily PnL: $100.00
Open Positions: 3      Closed Today: 2
Win Rate: 66.7%        Timestamp: 2025-01-15 14:30:00 UTC
```

### Command Examples

#### Check Bot Status
```
/bot-status
```
Returns current trading status, open positions, daily PnL, and system health.

#### Show Current Positions
```
/bot-positions open
/bot-positions BTC
/bot-positions
```

#### Get PnL Report
```
/bot-pnl today
/bot-pnl week
/bot-pnl month
```

#### Emergency Stop
```
/bot-stop
```
Immediately stops all trading activities and closes open positions.

### Interactive Features

#### Direct Messages
Send a direct message to the bot for basic help:
```
@FuturesBot help
```

#### Channel Mentions
Mention the bot in any channel for quick help:
```
@FuturesBot what's the status?
```

## Security

### Request Verification

All incoming Slack requests are verified using the signing secret to ensure they come from Slack. This prevents unauthorized access to bot commands.

### User Authorization

Commands can be restricted to specific users by setting `SLACK_AUTHORIZED_USERS`. If this environment variable is empty, all users in the workspace can use commands.

### Emergency Controls

The `/bot-stop` command provides immediate emergency stop functionality, allowing authorized users to quickly halt all trading activities.

## Error Handling

### Graceful Degradation

- If Slack is unavailable, the bot continues normal operations
- Failed notifications are logged but don't impact trading
- Retry logic with exponential backoff for temporary failures

### Error Notifications

Critical errors are automatically sent to the alerts channel:
```
🚨 Alert: Day Trading Position Management Error
Level: ERROR
Details: Database connection timeout
Timestamp: 2025-01-15 14:30:00 UTC
```

## Monitoring

### Health Checks

Access the Slack integration health status:
```bash
GET https://your-domain.com/slack/health
```

Returns:
```json
{
  "slack_enabled": true,
  "bot_token_configured": true,
  "signing_secret_configured": true,
  "api_connection": true,
  "bot_user_id": "U0BOTUSER",
  "team_name": "Your Team",
  "timestamp": "2025-01-15T14:30:00Z"
}
```

### Automated Health Checks

The `HealthCheckJob` runs hourly during trading hours and sends status updates to Slack when issues are detected.

### Logs

All Slack interactions are logged with appropriate detail levels:
```
[Slack] Message sent to #trading-signals
[Slack] Command received: /bot-status from U1234567890
[Slack] API Error: rate_limited - retrying in 2 seconds
```

## Troubleshooting

### Common Issues

#### Bot Not Responding to Commands
1. Check bot token validity
2. Verify request URL configuration
3. Ensure bot is invited to relevant channels
4. Check signing secret configuration

#### Notifications Not Appearing
1. Verify `SLACK_ENABLED=true`
2. Check channel names match configuration
3. Ensure bot has `chat:write` permission
4. Review application logs for errors

#### Unauthorized Command Responses
1. Check `SLACK_AUTHORIZED_USERS` configuration
2. Verify user IDs are correct (use "Copy member ID" in Slack)
3. Ensure users are in the workspace

### Debug Commands

Test the Slack integration:
```bash
# Check health endpoint
curl https://your-domain.com/slack/health

# Test notification (Rails console)
SlackNotificationService.bot_status({
  status: 'test',
  trading_active: true,
  healthy: true
})

# Test command handler (Rails console)
SlackCommandHandler.handle_command({
  command: '/bot-status',
  user_id: 'U1234567890',
  text: ''
})
```

## Performance Considerations

### Rate Limiting

- Slack API has rate limits (1 message per second per channel)
- The service includes retry logic with exponential backoff
- Critical notifications are prioritized

### Message Batching

- Position updates are batched to avoid spam
- Health checks only notify on status changes
- PnL updates are sent at reasonable intervals

### Fallback Mechanisms

- All notifications include fallback logging
- Trading continues if Slack is unavailable
- Essential bot functions work without Slack

## Development

### Testing

Run the Slack integration tests:
```bash
rspec spec/services/slack_notification_service_spec.rb
rspec spec/services/slack_command_handler_spec.rb
rspec spec/controllers/slack_controller_spec.rb
rspec spec/jobs/health_check_job_spec.rb
```

### Adding New Notifications

1. Add method to `SlackNotificationService`
2. Call from appropriate job or service
3. Add tests for the new notification
4. Update documentation

### Adding New Commands

1. Add command handler to `SlackCommandHandler`
2. Add route if needed
3. Update help text
4. Add tests for the new command
5. Document the command

## Migration

### From Other Notification Systems

If migrating from other notification systems:

1. Update existing notification calls to use `SlackNotificationService`
2. Configure Slack channels to match existing workflow
3. Test notification delivery
4. Gradually migrate users to Slack commands

### Deployment Considerations

- Test in staging environment first
- Configure channels before enabling notifications
- Train users on new commands
- Monitor logs during initial deployment