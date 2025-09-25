# frozen_string_literal: true

require "rails_helper"

RSpec.describe Api::ChatMessagesController, type: :controller do
  let(:mock_chat_bot) { instance_double(ChatBotService) }
  let(:session_id) { SecureRandom.uuid }

  before do
    allow(ChatBotService).to receive(:new).and_return(mock_chat_bot)
  end

  describe "Content-Type validation" do
    it "rejects non-JSON requests" do
      post :create, params: {message: "test"}

      expect(response).to have_http_status(:unsupported_media_type)
      expect(JSON.parse(response.body)["error"]).to eq("Content-Type must be application/json")
    end

    it "accepts JSON format parameter" do
      allow(mock_chat_bot).to receive(:process).and_return("Bot response")

      post :create, params: {message: "test", format: :json}

      expect(response).to have_http_status(:ok)
    end
  end

  describe "Session ID handling" do
    it "uses X-Chat-Session-ID header when provided" do
      request.headers["X-Chat-Session-ID"] = session_id
      request.headers["Content-Type"] = "application/json"

      allow(mock_chat_bot).to receive(:process).and_return("Bot response")

      post :create, params: {message: "test"}

      expect(ChatBotService).to have_received(:new).with(session_id)
    end

    it "uses session_id parameter when header not provided" do
      request.headers["Content-Type"] = "application/json"

      allow(mock_chat_bot).to receive(:process).and_return("Bot response")

      post :create, params: {message: "test", session_id: session_id}

      expect(ChatBotService).to have_received(:new).with(session_id)
    end

    it "generates new session ID when none provided" do
      request.headers["Content-Type"] = "application/json"

      allow(mock_chat_bot).to receive(:process).and_return("Bot response")
      allow(SecureRandom).to receive(:uuid).and_return(session_id)

      post :create, params: {message: "test"}

      expect(ChatBotService).to have_received(:new).with(session_id)
    end

    it "stores session ID in session" do
      request.headers["Content-Type"] = "application/json"
      request.headers["X-Chat-Session-ID"] = session_id

      allow(mock_chat_bot).to receive(:process).and_return("Bot response")

      post :create, params: {message: "test"}

      expect(session[:chat_session_id]).to eq(session_id)
    end
  end

  describe "POST #create" do
    before do
      request.headers["Content-Type"] = "application/json"
      request.headers["X-Chat-Session-ID"] = session_id
    end

    it "processes message successfully" do
      bot_response = "Here are your current positions..."
      allow(mock_chat_bot).to receive(:process).with("show positions").and_return(bot_response)

      post :create, params: {message: "show positions"}

      expect(response).to have_http_status(:ok)

      json_response = JSON.parse(response.body)
      expect(json_response["success"]).to be(true)
      expect(json_response["data"]["session_id"]).to eq(session_id)
      expect(json_response["data"]["user_message"]).to eq("show positions")
      expect(json_response["data"]["bot_response"]).to eq(bot_response)
      expect(json_response["data"]["timestamp"]).to be_present
    end

    it "rejects blank messages" do
      post :create, params: {message: ""}

      expect(response).to have_http_status(:bad_request)

      json_response = JSON.parse(response.body)
      expect(json_response["success"]).to be(false)
      expect(json_response["error"]).to eq("Message cannot be blank")
    end

    it "rejects whitespace-only messages" do
      post :create, params: {message: "   \n\t  "}

      expect(response).to have_http_status(:bad_request)

      json_response = JSON.parse(response.body)
      expect(json_response["success"]).to be(false)
      expect(json_response["error"]).to eq("Message cannot be blank")
    end

    it "handles ChatBotService errors gracefully" do
      allow(mock_chat_bot).to receive(:process).and_raise(StandardError.new("Service unavailable"))

      post :create, params: {message: "test message"}

      expect(response).to have_http_status(:internal_server_error)

      json_response = JSON.parse(response.body)
      expect(json_response["success"]).to be(false)
      expect(json_response["error"]).to eq("Failed to process message")
      expect(json_response["message"]).to eq("Service unavailable")
    end

    it "logs errors to Rails logger" do
      allow(mock_chat_bot).to receive(:process).and_raise(StandardError.new("Test error"))
      allow(Rails.logger).to receive(:error)

      post :create, params: {message: "test"}

      expect(Rails.logger).to have_received(:error).with(/ChatMessagesController#create.*Test error/)
    end
  end

  describe "GET #index" do
    before do
      request.headers["Content-Type"] = "application/json"
      request.headers["X-Chat-Session-ID"] = session_id
    end

    it "returns conversation history successfully" do
      conversation_data = {
        interactions: [
          {user_input: "hello", bot_response: "Hi there!", timestamp: Time.current},
          {user_input: "show positions", bot_response: "You have 2 open positions", timestamp: Time.current}
        ],
        total_interactions: 2,
        session_started: 1.hour.ago
      }

      allow(mock_chat_bot).to receive(:session_summary).and_return(conversation_data)

      get :index

      expect(response).to have_http_status(:ok)

      json_response = JSON.parse(response.body)
      expect(json_response["success"]).to be(true)
      expect(json_response["data"]["session_id"]).to eq(session_id)
      # Compare the parsed JSON rather than the original Ruby objects
      expect(json_response["data"]["messages"].length).to eq(2)
      expect(json_response["data"]["messages"][0]["user_input"]).to eq("hello")
      expect(json_response["data"]["messages"][0]["bot_response"]).to eq("Hi there!")
      expect(json_response["data"]["total_interactions"]).to eq(2)
    end

    it "handles empty conversation history" do
      allow(mock_chat_bot).to receive(:session_summary).and_return({})

      get :index

      expect(response).to have_http_status(:ok)

      json_response = JSON.parse(response.body)
      expect(json_response["success"]).to be(true)
      expect(json_response["data"]["messages"]).to eq([])
      expect(json_response["data"]["total_interactions"]).to eq(0)
    end

    it "handles ChatBotService errors gracefully" do
      allow(mock_chat_bot).to receive(:session_summary).and_raise(StandardError.new("Memory service error"))

      get :index

      expect(response).to have_http_status(:internal_server_error)

      json_response = JSON.parse(response.body)
      expect(json_response["success"]).to be(false)
      expect(json_response["error"]).to eq("Failed to retrieve conversation history")
    end
  end

  describe "POST #send_message" do
    before do
      request.headers["Content-Type"] = "application/json"
    end

    it "aliases to create action" do
      allow(mock_chat_bot).to receive(:process).and_return("Response")

      post :send_message, params: {message: "test"}

      expect(response).to have_http_status(:ok)
      expect(mock_chat_bot).to have_received(:process).with("test")
    end
  end

  describe "GET #conversation_history" do
    before do
      request.headers["Content-Type"] = "application/json"
    end

    it "aliases to index action" do
      allow(mock_chat_bot).to receive(:session_summary).and_return({})

      get :conversation_history

      expect(response).to have_http_status(:ok)
      expect(mock_chat_bot).to have_received(:session_summary)
    end
  end

  describe "API controller inheritance" do
    it "inherits from ApplicationController which inherits from ActionController::API" do
      expect(Api::ChatMessagesController.ancestors).to include(ApplicationController)
      expect(ApplicationController.ancestors).to include(ActionController::API)
    end
  end

  describe "JSON-only responses" do
    it "ensures all responses are JSON format" do
      request.headers["Content-Type"] = "application/json"
      allow(mock_chat_bot).to receive(:process).and_return("Response")

      post :create, params: {message: "test"}

      expect(response.content_type).to include("application/json")
    end
  end
end
