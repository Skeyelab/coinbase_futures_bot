# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatMemoryService, type: :service do
  let(:session_id) { SecureRandom.uuid }
  let(:service) { described_class.new(session_id) }
  let(:session) { ChatSession.find_by(session_id: session_id) }

  describe "#initialize" do
    it "creates or finds chat session" do
      expect { service }.to change(ChatSession, :count).by(1)
      expect(session).to be_present
      expect(session.session_id).to eq(session_id)
    end

    context "when session already exists" do
      let!(:existing_session) { create(:chat_session, session_id: session_id) }

      it "uses existing session" do
        expect { service }.not_to change(ChatSession, :count)
        expect(service.instance_variable_get(:@session)).to eq(existing_session)
      end
    end
  end

  describe "#store" do
    it "creates a chat message with correct attributes" do
      expect {
        service.store("Test content", :user, :high)
      }.to change(ChatMessage, :count).by(1)

      message = ChatMessage.last
      expect(message.content).to eq("Test content")
      expect(message.message_type).to eq("user")
      expect(message.profit_impact).to eq("high")
      expect(message.chat_session).to eq(session)
    end

    it "calculates relevance score based on profit impact" do
      service.store("Trading position", :user, :high)
      message = ChatMessage.last
      expect(message.relevance_score).to eq(5.0)
    end

    it "truncates long content" do
      long_content = "a" * 3000
      service.store(long_content, :user, :unknown)
      message = ChatMessage.last
      expect(message.content.length).to eq(2000)
    end

    it "updates session timestamp" do
      original_time = session.updated_at
      travel_to(1.hour.from_now) do
        service.store("Test", :user)
        expect(session.reload.updated_at).to be > original_time
      end
    end

    context "when session has too many messages" do
      before do
        create_list(:chat_message, 201, chat_session: session)
      end

      it "prunes old messages" do
        expect {
          service.store("New message", :user, :high)
        }.to change { session.chat_messages.count }.from(201).to(101)
      end
    end
  end

  describe "#store_user_input" do
    it "determines profit impact from input content" do
      service.store_user_input("Check my position")
      message = ChatMessage.last
      expect(message.profit_impact).to eq("high")
      expect(message.message_type).to eq("user")
    end

    it "assigns medium impact for market queries" do
      service.store_user_input("Show market data")
      message = ChatMessage.last
      expect(message.profit_impact).to eq("medium")
    end

    it "assigns low impact for help queries" do
      service.store_user_input("What can you help me with?")
      message = ChatMessage.last
      expect(message.profit_impact).to eq("low")
    end
  end

  describe "#store_bot_response" do
    it "determines profit impact from command result" do
      command_result = {type: "position_data", data: {}}
      service.store_bot_response("Position summary", command_result)

      message = ChatMessage.last
      expect(message.profit_impact).to eq("high")
      expect(message.message_type).to eq("bot")
    end

    it "analyzes response content for trading relevance" do
      service.store_bot_response("Your profit is $1000", nil)
      message = ChatMessage.last
      expect(message.profit_impact).to eq("medium")
    end
  end

  describe "#context_for_ai" do
    let!(:profitable_messages) do
      [
        create(:chat_message, chat_session: session, profit_impact: :high, content: "High impact message", timestamp: 3.hours.ago),
        create(:chat_message, chat_session: session, profit_impact: :medium, content: "Medium impact message", timestamp: 2.hours.ago),
        create(:chat_message, chat_session: session, profit_impact: :high, content: "Recent high impact", timestamp: 1.hour.ago)
      ]
    end

    let!(:non_profitable_messages) do
      create_list(:chat_message, 5, chat_session: session, profit_impact: :unknown, timestamp: 4.hours.ago)
    end

    it "returns only profitable messages" do
      context = service.context_for_ai(4000)
      expect(context).to include("High impact message")
      expect(context).to include("Medium impact message")
      expect(context).to include("Recent high impact")
      non_profitable_messages.each do |msg|
        expect(context).not_to include(msg.content)
      end
    end

    it "respects token limits" do
      # Create messages that would exceed token limit
      create_list(:chat_message, 50, chat_session: session, profit_impact: :high, content: "a" * 200)

      context = service.context_for_ai(1000) # Small limit
      expect(context.length).to be <= 1000
    end

    it "orders messages chronologically in output" do
      context = service.context_for_ai(4000)
      lines = context.split("\n")

      # Should be in chronological order (oldest first in final output)
      expect(lines.first).to include("High impact message")
      expect(lines.last).to include("Recent high impact")
    end
  end

  describe "#recent_interactions" do
    let!(:messages) do
      [
        create(:chat_message, chat_session: session, content: "First message", timestamp: 3.hours.ago),
        create(:chat_message, chat_session: session, content: "Second message", timestamp: 2.hours.ago),
        create(:chat_message, chat_session: session, content: "Third message", timestamp: 1.hour.ago)
      ]
    end

    it "returns recent interactions in correct format" do
      interactions = service.recent_interactions(2)

      expect(interactions.length).to eq(2)
      expect(interactions.first[:input]).to eq("Third message")
      expect(interactions.last[:input]).to eq("Second message")
    end

    it "includes timestamp in ISO format" do
      interactions = service.recent_interactions(1)
      expect(interactions.first[:timestamp]).to match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/)
    end
  end

  describe "#search_history" do
    let!(:matching_messages) do
      [
        create(:chat_message, chat_session: session, content: "BTC position update", profit_impact: :high),
        create(:chat_message, chat_session: session, content: "Bitcoin trading signal", profit_impact: :medium)
      ]
    end

    let!(:non_matching_messages) do
      create_list(:chat_message, 3, chat_session: session, content: "ETH market data", profit_impact: :low)
    end

    it "finds messages matching query" do
      results = service.search_history("BTC")
      expect(results.length).to eq(1)
      expect(results.first[0]).to include("BTC position update")
    end

    it "searches case-insensitively" do
      results = service.search_history("bitcoin")
      expect(results.length).to eq(1)
      expect(results.first[0]).to include("Bitcoin trading signal")
    end

    it "returns only profitable messages" do
      results = service.search_history("market")
      expect(results).to be_empty # ETH messages are low profit impact
    end

    it "limits results to 10" do
      create_list(:chat_message, 15, chat_session: session, content: "BTC test", profit_impact: :high)
      results = service.search_history("BTC")
      expect(results.length).to eq(10)
    end
  end

  describe "#session_summary" do
    let!(:messages) do
      [
        create(:chat_message, chat_session: session, profit_impact: :high),
        create(:chat_message, chat_session: session, profit_impact: :medium),
        create(:chat_message, chat_session: session, profit_impact: :low)
      ]
    end

    it "returns comprehensive session information" do
      summary = service.session_summary

      expect(summary[:session_id]).to eq(session_id)
      expect(summary[:total_interactions]).to eq(3)
      expect(summary[:profitable_messages]).to eq(2)
      expect(summary[:active]).to be true
      expect(summary[:last_activity]).to be_present
    end
  end

  describe "#clear_session" do
    let!(:messages) { create_list(:chat_message, 5, chat_session: session) }

    it "destroys all messages in session" do
      expect { service.clear_session }.to change { session.chat_messages.count }.from(5).to(0)
    end
  end

  describe "#deactivate_session" do
    it "sets session as inactive" do
      expect { service.deactivate_session }.to change { session.reload.active }.from(true).to(false)
    end
  end

  describe "private methods" do
    describe "#calculate_relevance_score" do
      it "assigns high score for high profit impact" do
        service.store("Test", :user, :high)
        message = ChatMessage.last
        expect(message.relevance_score).to eq(5.0)
      end

      it "boosts score for trading keywords" do
        service.store("position update", :user, :low)
        message = ChatMessage.last
        expect(message.relevance_score).to eq(2.5) # 2.0 base + 0.5 boost
      end

      it "boosts score for successful bot responses" do
        service.store("success: order executed", :bot, :unknown)
        message = ChatMessage.last
        expect(message.relevance_score).to eq(1.5) # 1.0 base + 0.5 boost
      end

      it "caps score at 5.0" do
        service.store("successful position trade completed", :bot, :high)
        message = ChatMessage.last
        expect(message.relevance_score).to eq(5.0) # Would be 6.0 but capped
      end
    end

    describe "#prune_old_messages" do
      before do
        # Create messages with different relevance scores and timestamps
        create_list(:chat_message, 50, chat_session: session, relevance_score: 1.0, timestamp: 5.hours.ago)
        create_list(:chat_message, 50, chat_session: session, relevance_score: 3.0, timestamp: 3.hours.ago)
        create_list(:chat_message, 50, chat_session: session, relevance_score: 5.0, timestamp: 1.hour.ago)
      end

      it "keeps top 100 messages by relevance and recency" do
        service.send(:prune_old_messages)
        expect(session.chat_messages.count).to eq(100)
      end

      it "prioritizes high relevance messages" do
        service.send(:prune_old_messages)
        remaining_scores = session.chat_messages.pluck(:relevance_score)
        expect(remaining_scores.count(5.0)).to eq(50) # All high relevance kept
        expect(remaining_scores.count(1.0)).to eq(0)  # All low relevance removed
      end
    end
  end
end
