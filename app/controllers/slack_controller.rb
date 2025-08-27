# frozen_string_literal: true

class SlackController < ApplicationController
  # Disable CSRF protection for webhook endpoints
  skip_before_action :verify_authenticity_token, only: [:commands, :events]

  # Handle Slack slash commands
  def commands
    # Verify request comes from Slack
    unless verify_slack_request(request)
      render json: {error: "Unauthorized"}, status: :unauthorized and return
    end

    # Handle URL verification challenge
    if params[:type] == "url_verification"
      render json: {challenge: params[:challenge]} and return
    end

    # Process command
    response = SlackCommandHandler.handle_command(slack_command_params)

    render json: response
  rescue => e
    Rails.logger.error("[SlackController] Error handling command: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))

    render json: {
      text: "❌ Error processing command. Please try again.",
      response_type: "ephemeral"
    }
  end

  # Handle Slack Events API (for interactive components, etc.)
  def events
    # Verify request comes from Slack
    unless verify_slack_request(request)
      render json: {error: "Unauthorized"}, status: :unauthorized and return
    end

    # Handle URL verification challenge
    if params[:type] == "url_verification"
      render json: {challenge: params[:challenge]} and return
    end

    # Handle other event types if needed
    case params[:type]
    when "event_callback"
      handle_event_callback
    else
      Rails.logger.info("[SlackController] Unhandled event type: #{params[:type]}")
    end

    render json: {ok: true}
  rescue => e
    Rails.logger.error("[SlackController] Error handling event: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))

    render json: {ok: false}
  end

  # Health check endpoint specifically for Slack integration
  def health
    health_status = {
      slack_enabled: ENV["SLACK_ENABLED"]&.downcase == "true",
      bot_token_configured: ENV["SLACK_BOT_TOKEN"].present?,
      signing_secret_configured: ENV["SLACK_SIGNING_SECRET"].present?,
      timestamp: Time.current.iso8601
    }

    if health_status[:slack_enabled] && health_status[:bot_token_configured]
      # Test Slack API connection
      begin
        client = Slack::Web::Client.new(token: ENV["SLACK_BOT_TOKEN"])
        auth_test = client.auth_test
        health_status[:api_connection] = true
        health_status[:bot_user_id] = auth_test["user_id"]
        health_status[:team_name] = auth_test["team"]
      rescue => e
        health_status[:api_connection] = false
        health_status[:api_error] = e.message
      end
    else
      health_status[:api_connection] = false
      health_status[:api_error] = "Slack not properly configured"
    end

    status_code = health_status[:api_connection] ? :ok : :service_unavailable
    render json: health_status, status: status_code
  end

  private

  def slack_command_params
    {
      token: params[:token],
      team_id: params[:team_id],
      team_domain: params[:team_domain],
      channel_id: params[:channel_id],
      channel_name: params[:channel_name],
      user_id: params[:user_id],
      user_name: params[:user_name],
      command: params[:command],
      text: params[:text],
      response_url: params[:response_url],
      trigger_id: params[:trigger_id]
    }
  end

  def verify_slack_request(request)
    return true unless ENV["SLACK_SIGNING_SECRET"].present?

    begin
      slack_signing_secret = ENV["SLACK_SIGNING_SECRET"]
      timestamp = request.headers["X-Slack-Request-Timestamp"]
      signature = request.headers["X-Slack-Signature"]

      # Check if request is too old (replay attack protection)
      if Time.current.to_i - timestamp.to_i > 300 # 5 minutes
        Rails.logger.warn("[SlackController] Request timestamp too old")
        return false
      end

      # Get raw request body
      body = request.raw_post

      # Create signature base string
      sig_basestring = "v0:#{timestamp}:#{body}"

      # Calculate expected signature
      expected_signature = "v0=" + OpenSSL::HMAC.hexdigest("SHA256", slack_signing_secret, sig_basestring)

      # Compare signatures
      ActiveSupport::SecurityUtils.secure_compare(expected_signature, signature)
    rescue => e
      Rails.logger.error("[SlackController] Error verifying Slack request: #{e.message}")
      false
    end
  end

  def handle_event_callback
    event = params[:event]

    case event[:type]
    when "message"
      # Handle direct messages to the bot if needed
      handle_direct_message(event) if event[:channel_type] == "im"
    when "app_mention"
      # Handle @bot mentions
      handle_app_mention(event)
    else
      Rails.logger.info("[SlackController] Unhandled event callback type: #{event[:type]}")
    end
  end

  def handle_direct_message(event)
    # For now, just respond with help
    return if event[:bot_id] # Ignore bot messages

    begin
      client = Slack::Web::Client.new(token: ENV["SLACK_BOT_TOKEN"])
      client.chat_postMessage(
        channel: event[:channel],
        text: "👋 Hi! I'm the Coinbase Futures Trading Bot. Use slash commands like `/bot-status` or `/bot-help` to interact with me.",
        as_user: true
      )
    rescue => e
      Rails.logger.error("[SlackController] Error responding to DM: #{e.message}")
    end
  end

  def handle_app_mention(event)
    # Handle @bot mentions in channels
    return if event[:bot_id] # Ignore bot messages

    text = event[:text].to_s.downcase

    response_text = if text.include?("help")
      "Hi! 👋 Use these slash commands to interact with me:\n" \
                      "• `/bot-status` - Bot status\n" \
                      "• `/bot-positions` - Current positions\n" \
                      "• `/bot-pnl` - PnL report\n" \
                      "• `/bot-help` - Full command list"
    elsif text.include?("status")
      "Use `/bot-status` to get the current bot status with detailed information."
    else
      "I'm here! Use `/bot-help` to see all available commands."
    end

    begin
      client = Slack::Web::Client.new(token: ENV["SLACK_BOT_TOKEN"])
      client.chat_postMessage(
        channel: event[:channel],
        text: response_text,
        thread_ts: event[:ts] # Reply in thread
      )
    rescue => e
      Rails.logger.error("[SlackController] Error responding to mention: #{e.message}")
    end
  end
end
