# frozen_string_literal: true

class Api::ChatMessagesController < ApplicationController
  # API controller inherits from ActionController::API, no CSRF by default

  # Ensure we're only responding with JSON
  before_action :ensure_json_request
  before_action :set_session_id
  before_action :set_chat_bot_service

  def index
    # Return recent messages from memory/cache
    conversation_history = @chat_bot.session_summary

    render json: {
      success: true,
      data: {
        session_id: @session_id,
        messages: conversation_history[:interactions] || [],
        total_interactions: conversation_history[:total_interactions] || 0,
        session_started: conversation_history[:session_started]
      }
    }, status: :ok
  rescue => e
    Rails.logger.error("[ChatMessagesController#index] Error: #{e.message}")
    render json: {
      success: false,
      error: "Failed to retrieve conversation history",
      message: e.message
    }, status: :internal_server_error
  end

  def create
    message = params[:message]&.strip

    if message.blank?
      return render json: {
        success: false,
        error: "Message cannot be blank"
      }, status: :bad_request
    end

    # Process message through ChatBotService
    response = @chat_bot.process(message)

    render json: {
      success: true,
      data: {
        session_id: @session_id,
        user_message: message,
        bot_response: response,
        timestamp: Time.current.iso8601
      }
    }, status: :ok
  rescue => e
    Rails.logger.error("[ChatMessagesController#create] Error: #{e.message}")
    render json: {
      success: false,
      error: "Failed to process message",
      message: e.message
    }, status: :internal_server_error
  end

  def send_message
    # Alias for create action - provides more RESTful endpoint name
    create
  end

  def conversation_history
    # Alias for index action - provides more descriptive endpoint name
    index
  end

  private

  def ensure_json_request
    unless request.content_type&.include?("application/json") || params[:format] == "json"
      render json: {
        success: false,
        error: "Content-Type must be application/json"
      }, status: :unsupported_media_type
    end
  end

  def set_session_id
    # Get session ID from header, params, or generate new one
    @session_id = request.headers["X-Chat-Session-ID"] ||
      params[:session_id] ||
      session[:chat_session_id] ||
      SecureRandom.uuid

    # Store in session for consistency
    session[:chat_session_id] = @session_id
  end

  def set_chat_bot_service
    @chat_bot = ChatBotService.new(@session_id)
  end
end
