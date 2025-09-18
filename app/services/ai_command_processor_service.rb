# frozen_string_literal: true

require "faraday"
require "json"

class AiCommandProcessorService
  include SentryServiceTracking

  # API endpoints
  OPENROUTER_API_URL = "https://openrouter.ai/api/v1"
  OPENAI_API_URL = "https://api.openai.com/v1"

  # Default models
  DEFAULT_OPENROUTER_MODEL = "anthropic/claude-3.5-sonnet"
  DEFAULT_OPENAI_MODEL = "gpt-4"

  # Request timeouts (in seconds)
  REQUEST_TIMEOUT = 30
  CONNECT_TIMEOUT = 10

  # Retry configuration
  MAX_RETRIES = 3
  RETRY_DELAY = 1

  class ApiError < StandardError
    attr_reader :response_body, :status_code

    def initialize(message, response_body: nil, status_code: nil)
      super(message)
      @response_body = response_body
      @status_code = status_code
    end
  end

  class ConfigurationError < StandardError; end

  def initialize
    validate_configuration!
    setup_clients
  end

  # Main entry point for processing AI commands
  def process_command(user_input, context: {}, model_preference: nil)
    track_service_call("process_command", user_input_length: user_input.length, context: context.keys) do
      # Try OpenRouter first (primary service)

      result = call_openrouter(user_input, context: context, model: model_preference)
      Rails.logger.info("Successfully processed command via OpenRouter")
      result
    rescue => e
      Rails.logger.warn("OpenRouter failed: #{e.message}. Falling back to ChatGPT")

      # Fallback to ChatGPT
      begin
        result = call_chatgpt(user_input, context: context, model: model_preference)
        Rails.logger.info("Successfully processed command via ChatGPT fallback")
        result
      rescue => fallback_error
        Rails.logger.error("Both OpenRouter and ChatGPT failed. OpenRouter: #{e.message}, ChatGPT: #{fallback_error.message}")
        raise ApiError.new("All AI services failed", response_body: fallback_error.message)
      end
    end
  end

  # Direct OpenRouter API call
  def call_openrouter(user_input, context: {}, model: nil)
    model ||= DEFAULT_OPENROUTER_MODEL

    track_external_api_call("openrouter", "/chat/completions", "process_command", model: model) do
      payload = build_openrouter_payload(user_input, context: context, model: model)

      with_retry do
        response = @openrouter_client.post("/chat/completions") do |req|
          req.headers["Authorization"] = "Bearer #{@openrouter_api_key}"
          req.headers["Content-Type"] = "application/json"
          req.headers["HTTP-Referer"] = ENV.fetch("APP_URL", "http://localhost:3000")
          req.headers["X-Title"] = "Coinbase Futures Bot"
          req.body = payload.to_json
        end

        parse_openrouter_response(response)
      end
    end
  end

  # Direct ChatGPT API call
  def call_chatgpt(user_input, context: {}, model: nil)
    model ||= DEFAULT_OPENAI_MODEL

    track_external_api_call("openai", "/chat/completions", "process_command", model: model) do
      payload = build_chatgpt_payload(user_input, context: context, model: model)

      with_retry do
        response = @openai_client.post("/chat/completions") do |req|
          req.headers["Authorization"] = "Bearer #{@openai_api_key}"
          req.headers["Content-Type"] = "application/json"
          req.body = payload.to_json
        end

        parse_chatgpt_response(response)
      end
    end
  end

  # Get available models from OpenRouter
  def available_models
    track_external_api_call("openrouter", "/models", "list_models") do
      with_retry do
        response = @openrouter_client.get("/models") do |req|
          req.headers["Authorization"] = "Bearer #{@openrouter_api_key}"
        end

        JSON.parse(response.body)["data"]
      end
    end
  rescue => e
    Rails.logger.error("Failed to fetch available models: #{e.message}")
    []
  end

  # Health check method
  def healthy?
    return false unless @openrouter_api_key.present? || @openai_api_key.present?

    # Quick test with minimal input
    test_input = "Hello"
    result = process_command(test_input, context: {})
    result.present?
  rescue
    false
  end

  private

  def validate_configuration!
    @openrouter_api_key = ENV["OPENROUTER_API_KEY"]
    @openai_api_key = ENV["OPENAI_API_KEY"]

    if @openrouter_api_key.blank? && @openai_api_key.blank?
      raise ConfigurationError, "At least one API key must be configured: OPENROUTER_API_KEY or OPENAI_API_KEY"
    end

    Rails.logger.info("AI Service configured with: #{configured_services.join(", ")}")
  end

  def configured_services
    services = []
    services << "OpenRouter" if @openrouter_api_key.present?
    services << "OpenAI" if @openai_api_key.present?
    services
  end

  def setup_clients
    # OpenRouter client
    if @openrouter_api_key.present?
      @openrouter_client = Faraday.new(OPENROUTER_API_URL) do |f|
        f.request :url_encoded
        f.response :raise_error
        f.adapter Faraday.default_adapter
        f.options.timeout = REQUEST_TIMEOUT
        f.options.open_timeout = CONNECT_TIMEOUT
      end
    end

    # OpenAI client
    if @openai_api_key.present?
      @openai_client = Faraday.new(OPENAI_API_URL) do |f|
        f.request :url_encoded
        f.response :raise_error
        f.adapter Faraday.default_adapter
        f.options.timeout = REQUEST_TIMEOUT
        f.options.open_timeout = CONNECT_TIMEOUT
      end
    end
  end

  def build_openrouter_payload(user_input, context: {}, model: DEFAULT_OPENROUTER_MODEL)
    messages = build_messages(user_input, context: context)

    {
      model: model,
      messages: messages,
      max_tokens: 1000,
      temperature: 0.7,
      top_p: 1,
      frequency_penalty: 0,
      presence_penalty: 0
    }
  end

  def build_chatgpt_payload(user_input, context: {}, model: DEFAULT_OPENAI_MODEL)
    messages = build_messages(user_input, context: context)

    {
      model: model,
      messages: messages,
      max_tokens: 1000,
      temperature: 0.7,
      top_p: 1,
      frequency_penalty: 0,
      presence_penalty: 0
    }
  end

  def build_messages(user_input, context: {})
    messages = []

    # System message with context about the trading bot
    system_content = build_system_message(context)
    messages << {role: "system", content: system_content}

    # User message
    messages << {role: "user", content: sanitize_input(user_input)}

    messages
  end

  def build_system_message(context)
    base_message = <<~SYSTEM
      You are an AI assistant for a Coinbase futures trading bot. You help users understand and interact with their trading system.
      
      The bot includes:
      - Real-time market data processing
      - Multi-timeframe technical analysis (1min, 5min, 15min, 1h)
      - Day trading and swing trading strategies
      - Risk management and position sizing
      - Paper trading simulation
      - Slack notifications and alerts
      
      Always provide helpful, accurate information about trading operations while emphasizing risk management.
      Keep responses concise and actionable.
    SYSTEM

    # Add context-specific information
    if context.present?
      context_info = context.map { |k, v| "#{k}: #{v}" }.join("\n")
      base_message += "\n\nCurrent context:\n#{context_info}"
    end

    base_message
  end

  def sanitize_input(input)
    # Remove potentially harmful content and limit length
    sanitized = input.to_s.strip
    sanitized = sanitized[0..4000] if sanitized.length > 4000  # Limit to 4000 chars
    sanitized
  end

  def parse_openrouter_response(response)
    body = JSON.parse(response.body)

    if body["error"]
      raise ApiError.new("OpenRouter API error: #{body["error"]["message"]}",
        response_body: body, status_code: response.status)
    end

    content = body.dig("choices", 0, "message", "content")
    unless content
      raise ApiError.new("Invalid response format from OpenRouter",
        response_body: body, status_code: response.status)
    end

    {
      content: content,
      model: body["model"],
      usage: body["usage"],
      provider: "openrouter"
    }
  end

  def parse_chatgpt_response(response)
    body = JSON.parse(response.body)

    if body["error"]
      raise ApiError.new("OpenAI API error: #{body["error"]["message"]}",
        response_body: body, status_code: response.status)
    end

    content = body.dig("choices", 0, "message", "content")
    unless content
      raise ApiError.new("Invalid response format from OpenAI",
        response_body: body, status_code: response.status)
    end

    {
      content: content,
      model: body["model"],
      usage: body["usage"],
      provider: "openai"
    }
  end

  def with_retry(max_attempts: MAX_RETRIES, delay: RETRY_DELAY)
    attempts = 0
    begin
      attempts += 1
      yield
    rescue Faraday::TimeoutError, Faraday::ConnectionFailed => e
      if attempts < max_attempts
        Rails.logger.warn("API call failed (attempt #{attempts}/#{max_attempts}): #{e.message}. Retrying in #{delay}s...")
        sleep(delay * attempts) # Exponential backoff
        retry
      else
        raise ApiError.new("API call failed after #{max_attempts} attempts: #{e.message}")
      end
    rescue Faraday::ClientError => e
      # Don't retry client errors (4xx)
      error_body = e.response[:body] if e.response
      raise ApiError.new("API client error: #{e.message}",
        response_body: error_body, status_code: e.response&.dig(:status))
    rescue Faraday::ServerError => e
      # Retry server errors (5xx)
      if attempts < max_attempts
        Rails.logger.warn("Server error (attempt #{attempts}/#{max_attempts}): #{e.message}. Retrying in #{delay}s...")
        sleep(delay * attempts)
        retry
      else
        error_body = e.response[:body] if e.response
        raise ApiError.new("Server error after #{max_attempts} attempts: #{e.message}",
          response_body: error_body, status_code: e.response&.dig(:status))
      end
    end
  end
end
