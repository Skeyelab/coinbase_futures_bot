# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSession, type: :model do
  describe "validations" do
    it "validates presence of session_id" do
      session = build(:chat_session, session_id: nil)
      expect(session).not_to be_valid
      expect(session.errors[:session_id]).to include("can't be blank")
    end

    it "validates uniqueness of session_id" do
      create(:chat_session, session_id: "test-id")
      duplicate = build(:chat_session, session_id: "test-id")
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:session_id]).to include("has already been taken")
    end

    it "validates inclusion of active" do
      session = build(:chat_session)
      expect(session).to be_valid

      session.active = nil
      expect(session).not_to be_valid
    end
  end

  describe "associations" do
    it "has many chat_messages with dependent destroy" do
      session = create(:chat_session)
      create_list(:chat_message, 3, chat_session: session)

      expect { session.destroy }.to change(ChatMessage, :count).by(-3)
    end
  end

  describe "scopes" do
    let!(:recent_session) { create(:chat_session, updated_at: 1.hour.ago) }
    let!(:old_session) { create(:chat_session, updated_at: 1.day.ago) }
    let!(:active_session) { create(:chat_session, active: true) }
    let!(:inactive_session) { create(:chat_session, active: false) }

    describe ".recent" do
      it "orders by updated_at desc" do
        # Test with the specific records we created for this test
        recent_sessions = ChatSession.where(id: [recent_session.id, old_session.id]).recent
        expect(recent_sessions).to eq([recent_session, old_session])
      end
    end

    describe ".active" do
      it "returns only active sessions" do
        expect(ChatSession.active).to include(active_session)
        expect(ChatSession.active).not_to include(inactive_session)
      end
    end

    describe ".profitable" do
      let(:session_with_profitable_messages) { create(:chat_session) }
      let(:session_without_profitable_messages) { create(:chat_session) }

      before do
        create(:chat_message, chat_session: session_with_profitable_messages, profit_impact: :high)
        create(:chat_message, chat_session: session_without_profitable_messages, profit_impact: :unknown)
      end

      it "returns sessions with profitable messages" do
        expect(ChatSession.profitable).to include(session_with_profitable_messages)
        expect(ChatSession.profitable).not_to include(session_without_profitable_messages)
      end
    end
  end

  describe ".find_or_create_by_session_id" do
    let(:session_id) { SecureRandom.uuid }

    context "when session exists" do
      let!(:existing_session) { create(:chat_session, session_id: session_id) }

      it "returns existing session" do
        result = ChatSession.find_or_create_by_session_id(session_id)
        expect(result).to eq(existing_session)
      end
    end

    context "when session doesn't exist" do
      it "creates new session" do
        expect {
          ChatSession.find_or_create_by_session_id(session_id)
        }.to change(ChatSession, :count).by(1)
      end

      it "returns new session with correct session_id" do
        result = ChatSession.find_or_create_by_session_id(session_id)
        expect(result.session_id).to eq(session_id)
      end
    end
  end

  describe "#message_count" do
    let(:session) { create(:chat_session) }

    it "returns count of associated messages" do
      create_list(:chat_message, 3, chat_session: session)
      expect(session.message_count).to eq(3)
    end
  end

  describe "#last_activity" do
    let(:session) { create(:chat_session, updated_at: 2.hours.ago) }

    context "when session has messages" do
      it "returns timestamp of most recent message" do
        recent_message = create(:chat_message, chat_session: session, timestamp: 1.hour.ago)
        create(:chat_message, chat_session: session, timestamp: 3.hours.ago)

        expect(session.last_activity).to be_within(1.second).of(recent_message.timestamp)
      end
    end

    context "when session has no messages" do
      it "returns session updated_at" do
        expect(session.last_activity).to be_within(1.second).of(session.updated_at)
      end
    end
  end

  describe "#profitable_messages" do
    let(:session) { create(:chat_session) }

    it "returns messages with medium or high profit impact" do
      high_message = create(:chat_message, chat_session: session, profit_impact: :high)
      medium_message = create(:chat_message, chat_session: session, profit_impact: :medium)
      create(:chat_message, chat_session: session, profit_impact: :low)
      create(:chat_message, chat_session: session, profit_impact: :unknown)

      profitable = session.profitable_messages
      expect(profitable).to include(high_message, medium_message)
      expect(profitable.count).to eq(2)
    end
  end

  describe "#deactivate!" do
    let(:session) { create(:chat_session, active: true) }

    it "sets active to false" do
      session.deactivate!
      expect(session.reload.active).to be false
    end
  end
end
