# Slack Integration

## Overview

Slack is a **push-only** surface. The bot sends alerts *to* Slack; it accepts
nothing *from* Slack.

The inbound half — slash commands, event subscriptions, DMs, mentions — was
deleted in **[ADR 0007](adr/0007-one-conversational-control-plane.md)**. It was a
regex router over the same reads that `Mcp::Server` already serves by
delegation, and keeping two routers is what produced six position serializers and
six PnL formulas. MCP is the conversational control plane; `bin/futuresbot` is
the operator CLI. Neither reaches this file.

Everything below describes `app/services/slack_notification_service.rb`, which is
unchanged and has 18 caller files.

## Notifications

| Notification | Trigger |
|---|---|
| Trading signals | a new `SignalAlert` is generated |
| Position updates | position opened, increased, reduced, or closed |
| PnL reports | scheduled summaries |
| Health alerts | `HealthCheckJob` detects a degraded system |
| Error alerts | critical failures in trading paths |
| Margin window transitions | intraday/overnight margin step changes |

Examples:

```
🎯 New Trading Signal: BTC-USD
Symbol: BTC-USD        Side: LONG
Price: $50,000.00      Quantity: 0.1
Take Profit: $52,000   Stop Loss: $48,000
Confidence: 75%        Timestamp: 2025-01-15 14:30:00 UTC
```

```
🟢 Position Opened: ETH-USD
Symbol: ETH-USD        Side: LONG
Size: 1.0              Entry Price: $3,000.00
```

```
🚨 Alert: Day Trading Position Management Error
Level: ERROR
Details: Database connection timeout
Timestamp: 2025-01-15 14:30:00 UTC
```

## Setup

### 1. Slack app

Create an app at [api.slack.com](https://api.slack.com/apps).

**Bot token scopes** (OAuth & Permissions) — only what posting requires:

```
channels:read     - Read public channel information
chat:write        - Send messages
```

**No Event Subscriptions and no Slash Commands are needed.** There is no
request URL to configure; the app exposes no Slack-facing endpoint. If you are
upgrading an existing installation, remove the slash commands and the event
subscription — `POST /slack/commands`, `POST /slack/events`, and
`GET /slack/health` no longer resolve and will return 404.

### 2. Environment

```bash
# Enable Slack notifications
SLACK_ENABLED=true

# Bot credentials
SLACK_BOT_TOKEN=xoxb-your-bot-token-here

# Channel configuration
SLACK_SIGNALS_CHANNEL=#trading-signals
SLACK_POSITIONS_CHANNEL=#trading-positions
SLACK_STATUS_CHANNEL=#bot-status
SLACK_ALERTS_CHANNEL=#trading-alerts
SLACK_DAY_TRADING_CHANNEL=#day-trading
SLACK_MARGIN_ALERTS_CHANNEL=#margin-alerts
SLACK_RISK_ALERTS_CHANNEL=#risk-alerts
```

`SLACK_SIGNING_SECRET` and `SLACK_AUTHORIZED_USERS` are **inert**. They existed
to authorize inbound requests and nothing reads them. Leaving them set is
harmless; they grant nothing.

### 3. Channels

Create the channels named above and invite the bot to each one it must post to.

### 4. Dependencies

`slack-ruby-client` is already in the Gemfile. `bundle install`.

## Where the reads went

Anything the old slash commands returned is available from a surface that
delegates to `OperatorSnapshot` instead of re-deriving it:

| Old command | Replacement |
|---|---|
| `/bot-status` | `bin/futuresbot status` · MCP `get_status` |
| `/bot-positions` | `bin/futuresbot positions` · MCP `get_positions` |
| `/bot-pnl` | `bin/futuresbot positions` · MCP `get_positions` |
| `/bot-health` | `bin/futuresbot status` · `GET /health` |
| `/bot-pause` / `/bot-resume` | `bin/futuresbot halt` / `resume` · MCP `halt_trading` / `resume_trading` |
| `/bot-stop` | `bin/futuresbot halt --reason` · MCP `halt_trading` |

Per ADR 0005, halt and resume are OPERATOR actions and require a deliberate,
stated action from an authenticated human. Slack never met that bar — both of
its auth layers failed open until PR #512, and its intent came from a text
string.

## Error handling

- If Slack is unavailable, the bot continues trading normally.
- Failed notifications are logged and never block a trading path.
- Retry with exponential backoff on transient Slack API failures.

## Monitoring

Startup logs the effective configuration:

```
[Slack] Configuration status:
[Slack]   Enabled: true
[Slack]   Bot token configured: true
[Slack]   Signals channel: #trading-signals
[Slack]   ...
[Slack]   Direction: outbound only (inbound commands removed, ADR 0007)
```

Runtime:

```
[Slack] Message sent to #trading-signals
[Slack] API Error: rate_limited - retrying in 2 seconds
```

`HealthCheckJob` runs hourly during trading hours and posts to Slack when it
detects a problem.

## Troubleshooting

**Notifications not appearing**

1. Verify `SLACK_ENABLED=true`.
2. Check channel names match the configured values.
3. Ensure the bot has `chat:write` and is a member of the channel.
4. Review application logs for `[Slack] API Error`.

**A slash command returns "dispatch_failed" or 404**

Expected. Delete the slash command from the Slack app configuration — the
endpoint is gone (ADR 0007).

**Testing a notification** (Rails console):

```ruby
SlackNotificationService.bot_status(
  status: "test",
  trading_active: true,
  healthy: true
)
```

## Performance

- Slack rate-limits to roughly one message per second per channel; the service
  retries with backoff.
- Position updates are batched to avoid spam.
- Health checks notify on status *changes*, not on every run.

## Development

```bash
bundle exec rspec spec/services/slack_notification_service_spec.rb
bundle exec rspec spec/services/slack_notification_service_enhanced_spec.rb
bundle exec rspec spec/jobs/health_check_job_spec.rb
```

**Adding a notification**

1. Add a method to `SlackNotificationService`.
2. Call it from the relevant job or service.
3. Add a spec.
4. Update this document.

**Adding a command** — don't. Slack is push-only. A new inbound surface is a new
mutating surface and requires an ADR (ADR 0005, rule 2), and the argument would
have to explain what it gives the operator that MCP does not.
