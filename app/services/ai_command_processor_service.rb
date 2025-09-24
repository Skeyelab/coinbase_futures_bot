# frozen_string_literal: true

require 'faraday'
require 'json'

class AiCommandProcessorService
  include SentryServiceTracking

  OPENROUTER_URL = 'https://openrouter.ai/api/v1'
  OPENAI_URL = 'https://api.openai.com/v1'
  TIMEOUT = 30

  class ApiError < StandardError; end
  class ConfigurationError < StandardError; end

  def initialize
    @openrouter_key = ENV['OPENROUTER_API_KEY']
    @openai_key = ENV['OPENAI_API_KEY']

    raise ConfigurationError, 'At least one API key required' if [@openrouter_key, @openai_key].all?(&:blank?)

    setup_clients
  end

  def process_command(input, context: {})
    track_service_call('process_command') do
      # Try OpenRouter first, fallback to OpenAI
      call_openrouter(input, context: context)
    rescue StandardError => e
      Rails.logger.warn("OpenRouter failed: #{e.message}. Falling back to ChatGPT")
      call_chatgpt(input, context: context)
    end
  end

  def call_openrouter(input, context: {})
    raise ApiError, 'OpenRouter not configured' if @openrouter_key.blank?

    track_external_api_call('openrouter', '/chat/completions', 'process') do
      response = @openrouter_client.post("#{OPENROUTER_URL}/chat/completions") do |req|
        req.headers['Authorization'] = "Bearer #{@openrouter_key}"
        req.headers['Content-Type'] = 'application/json'
        req.body = build_payload(input, context: context, model: 'anthropic/claude-3.5-sonnet').to_json
      end

      parse_response(response, 'openrouter')
    end
  end

  def call_chatgpt(input, context: {})
    raise ApiError, 'OpenAI not configured' if @openai_key.blank?

    track_external_api_call('openai', '/chat/completions', 'process') do
      response = @openai_client.post("#{OPENAI_URL}/chat/completions") do |req|
        req.headers['Authorization'] = "Bearer #{@openai_key}"
        req.headers['Content-Type'] = 'application/json'
        req.body = build_payload(input, context: context, model: 'gpt-4').to_json
      end

      parse_response(response, 'openai')
    end
  end

  def healthy?
    return false if [@openrouter_key, @openai_key].all?(&:blank?)

    process_command('test').present?
  rescue StandardError
    false
  end

  private

  def setup_clients
    @openrouter_client = build_client if @openrouter_key.present?
    @openai_client = build_client if @openai_key.present?
  end

  def build_client
    Faraday.new do |f|
      f.response :raise_error
      f.options.timeout = TIMEOUT
    end
  end

  def build_payload(input, model:, context: {})
    {
      model: model,
      messages: [
        { role: 'system', content: system_message(context) },
        { role: 'user', content: input.to_s.strip[0..4000] }
      ],
      max_tokens: 1000,
      temperature: 0.7
    }
  end

  def system_message(context)
    base = 'You are an AI assistant for a Coinbase futures trading bot. Help users understand their trading system. Provide helpful, accurate information emphasizing risk management. Keep responses concise and actionable.'

    return base if context.blank?

    context_info = context.map { |k, v| "#{k}: #{v}" }.join(', ')
    "#{base}\n\nContext: #{context_info}"
  end

  def parse_response(response, provider)
    body = JSON.parse(response.body)

    raise ApiError, "#{provider.capitalize} error: #{body['error']['message']}" if body['error']

    content = body.dig('choices', 0, 'message', 'content')
    raise ApiError, 'Invalid response format' unless content

    {
      content: content,
      model: body['model'],
      usage: body['usage'],
      provider: provider
    }
  end
end
