# frozen_string_literal: true

class ChatController < ActionController::Base
  layout "application"

  # Enable CSRF protection for HTML requests
  protect_from_forgery with: :exception

  def index
    # Initialize session for chat if not present
    session[:chat_session_id] ||= SecureRandom.uuid

    # Set security headers
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-XSS-Protection"] = "1; mode=block"

    @session_id = session[:chat_session_id]
    @csrf_token = form_authenticity_token
  end
end
