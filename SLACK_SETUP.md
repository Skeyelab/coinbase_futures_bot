# Slack Integration Setup Guide

## 🚀 Quick Setup

### 1. Create Slack App

1. Go to [api.slack.com/apps](https://api.slack.com/apps)
2. Click "Create New App" → "From an app manifest"
3. Select your workspace
4. Copy and paste the manifest from `slack-app-manifest.json`
5. **IMPORTANT**: Update the `request_url` fields in the manifest:
   - Change `https://skeyelab.ngrok.io/slack/events` to your actual domain
   - Change `https://skeyelab.ngrok.io/slack/commands` to your actual domain
6. Click "Create"
7. Install the app to your workspace

### 2. Configure Slash Commands

After creating the app, you need to manually add the slash commands:

1. Go to your app's settings → "Slash Commands"
2. Add each command with these settings:

| Command | Request URL | Description |
|---------|-------------|-------------|
| `/bot-status` | `https://skeyelab.ngrok.io/slack/commands` | Show bot status |
| `/bot-pause` | `https://skeyelab.ngrok.io/slack/commands` | Pause trading |
| `/bot-resume` | `https://skeyelab.ngrok.io/slack/commands` | Resume trading |
| `/bot-positions` | `https://skeyelab.ngrok.io/slack/commands` | Show positions |
| `/bot-pnl` | `https://skeyelab.ngrok.io/slack/commands` | Show P&L report |
| `/bot-health` | `https://skeyelab.ngrok.io/slack/commands` | System health |
| `/bot-stop` | `https://skeyelab.ngrok.io/slack/commands` | Emergency stop |
| `/bot-help` | `https://skeyelab.ngrok.io/slack/commands` | Show help |

### 3. Get Your Credentials

1. **Bot Token**: Go to "OAuth & Permissions" → Copy the "Bot User OAuth Token"
2. **Signing Secret**: Go to "Basic Information" → Copy the "Signing Secret"
3. **Bot User ID**: After installing, find your bot in the workspace and copy its member ID

### 4. Set Environment Variables

Add these to your `.env` file:

```bash
# Enable Slack integration
SLACK_ENABLED=true

# Slack credentials
SLACK_BOT_TOKEN=xoxb-your-bot-token-here
SLACK_SIGNING_SECRET=your-signing-secret-here

# Channel configuration (create these channels first)
SLACK_SIGNALS_CHANNEL=#trading-signals
SLACK_POSITIONS_CHANNEL=#trading-positions
SLACK_STATUS_CHANNEL=#bot-status
SLACK_ALERTS_CHANNEL=#trading-alerts

# Authorized users (comma-separated Slack user IDs)
SLACK_AUTHORIZED_USERS=U1234567890,U0987654321
```

### 5. Create Channels

Create these channels in your Slack workspace:
- `#trading-signals`
- `#trading-positions`
- `#bot-status`
- `#trading-alerts`

### 6. Invite Bot to Channels

Invite your bot to all the channels where it needs to post messages.

### 7. Test the Integration

1. Restart your Rails application
2. Test the health endpoint: `GET https://skeyelab.ngrok.io/slack/health`
3. Test a command in Slack: `/bot-status`

## 🔧 Troubleshooting

### Bot Not Responding to Commands
- Check that your domain is publicly accessible
- Verify the request URLs in Slack app settings match your domain
- Check Rails logs for errors
- Ensure SSL certificate is valid (Slack requires HTTPS)

### Notifications Not Appearing
- Check `SLACK_ENABLED=true` in your environment
- Verify channel names match your configuration
- Ensure bot is invited to the channels
- Check that bot has proper permissions

### Unauthorized Command Responses
- Verify `SLACK_AUTHORIZED_USERS` contains correct user IDs
- User IDs should look like `U1234567890`
- Right-click on a user in Slack → "Copy member ID"

### Request Verification Failed
- Ensure `SLACK_SIGNING_SECRET` is correct
- Check that your Rails app is properly verifying requests
- The Slack integration includes automatic request verification

## 📱 Available Commands

| Command | Description | Example |
|---------|-------------|---------|
| `/bot-status` | Show bot status and statistics | `/bot-status` |
| `/bot-pause` | Pause trading operations | `/bot-pause` |
| `/bot-resume` | Resume trading operations | `/bot-resume` |
| `/bot-positions [filter]` | Show positions | `/bot-positions open` |
| `/bot-pnl [period]` | Show P&L report | `/bot-pnl today` |
| `/bot-health` | Show system health | `/bot-health` |
| `/bot-stop` | Emergency stop | `/bot-stop` |
| `/bot-help` | Show all commands | `/bot-help` |

## 🎯 Next Steps

1. Test all commands in a safe environment
2. Configure channel notifications
3. Set up monitoring alerts
4. Train your team on bot usage
5. Consider setting up emergency procedures

## 🆘 Support

If you encounter issues:
1. Check the Rails logs for detailed error messages
2. Test the `/slack/health` endpoint
3. Verify all environment variables are set
4. Ensure your domain is accessible from Slack's servers

The integration includes comprehensive logging and error handling to help with troubleshooting.
