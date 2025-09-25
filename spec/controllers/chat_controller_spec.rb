# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatController, type: :controller do
  describe "GET #index" do
    it "renders the chat interface successfully" do
      get :index

      expect(response).to have_http_status(:success)
      expect(response).to render_template(:index)
    end

    it "initializes a chat session ID if not present" do
      expect(session[:chat_session_id]).to be_nil

      get :index

      expect(session[:chat_session_id]).to be_present
      expect(session[:chat_session_id]).to match(/\A[0-9a-f-]{36}\z/)
    end

    it "preserves existing chat session ID" do
      existing_session_id = SecureRandom.uuid
      session[:chat_session_id] = existing_session_id

      get :index

      expect(session[:chat_session_id]).to eq(existing_session_id)
    end

    it "assigns session_id and csrf_token to view" do
      get :index

      expect(assigns(:session_id)).to be_present
      expect(assigns(:csrf_token)).to be_present
    end

    it "sets security headers" do
      get :index

      expect(response.headers["X-Frame-Options"]).to eq("DENY")
      expect(response.headers["X-Content-Type-Options"]).to eq("nosniff")
      expect(response.headers["X-XSS-Protection"]).to eq("1; mode=block")
    end

    it "inherits from ActionController::Base for HTML rendering" do
      expect(ChatController.ancestors).to include(ActionController::Base)
    end

    it "includes CSRF protection" do
      # Test that CSRF protection is enabled for this controller
      expect(controller.class._process_action_callbacks.find { |c| c.filter == :verify_authenticity_token }).to be_present
    end
  end

  describe "CSRF protection" do
    it "is enabled for the controller" do
      expect(controller.class.ancestors).to include(ActionController::RequestForgeryProtection)
    end
  end
end
