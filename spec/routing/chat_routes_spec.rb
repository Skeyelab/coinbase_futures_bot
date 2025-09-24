# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Chat Routes", type: :routing do
  describe "main chat interface route" do
    it "routes GET /chat to chat#index" do
      expect(get: "/chat").to route_to(controller: "chat", action: "index")
    end
  end

  describe "API chat message routes" do
    describe "RESTful routes" do
      it "routes GET /api/chat_messages to api/chat_messages#index" do
        expect(get: "/api/chat_messages").to route_to(controller: "api/chat_messages", action: "index")
      end

      it "routes POST /api/chat_messages to api/chat_messages#create" do
        expect(post: "/api/chat_messages").to route_to(controller: "api/chat_messages", action: "create")
      end

      it "does not route unsupported RESTful actions" do
        expect(get: "/api/chat_messages/1").not_to be_routable
        expect(put: "/api/chat_messages/1").not_to be_routable
        expect(patch: "/api/chat_messages/1").not_to be_routable
        expect(delete: "/api/chat_messages/1").not_to be_routable
      end
    end

    describe "collection routes" do
      it "routes POST /api/chat_messages/send_message to api/chat_messages#send_message" do
        expect(post: "/api/chat_messages/send_message").to route_to(
          controller: "api/chat_messages",
          action: "send_message"
        )
      end

      it "routes GET /api/chat_messages/conversation_history to api/chat_messages#conversation_history" do
        expect(get: "/api/chat_messages/conversation_history").to route_to(
          controller: "api/chat_messages",
          action: "conversation_history"
        )
      end
    end
  end

  describe "route helpers" do
    it "generates correct path for chat interface" do
      expect(chat_path).to eq("/chat")
    end

    it "generates correct paths for API endpoints" do
      expect(api_chat_messages_path).to eq("/api/chat_messages")
      expect(send_message_api_chat_messages_path).to eq("/api/chat_messages/send_message")
      expect(conversation_history_api_chat_messages_path).to eq("/api/chat_messages/conversation_history")
    end
  end

  describe "HTTP method constraints" do
    it "only allows GET for chat interface" do
      expect(get: "/chat").to be_routable
      expect(post: "/chat").not_to be_routable
      expect(put: "/chat").not_to be_routable
      expect(delete: "/chat").not_to be_routable
    end

    it "only allows specified methods for API endpoints" do
      # Index endpoint
      expect(get: "/api/chat_messages").to be_routable
      expect(post: "/api/chat_messages").to be_routable
      expect(put: "/api/chat_messages").not_to be_routable
      expect(delete: "/api/chat_messages").not_to be_routable

      # Custom collection endpoints
      expect(post: "/api/chat_messages/send_message").to be_routable
      expect(get: "/api/chat_messages/send_message").not_to be_routable

      expect(get: "/api/chat_messages/conversation_history").to be_routable
      expect(post: "/api/chat_messages/conversation_history").not_to be_routable
    end
  end

  describe "namespace verification" do
    it "correctly namespaces API routes under /api" do
      expect(get: "/api/chat_messages").to route_to(controller: "api/chat_messages", action: "index")
      expect(get: "/chat_messages").not_to be_routable
    end
  end
end
