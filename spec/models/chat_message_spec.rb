# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatMessage, type: :model do
  describe "validations" do
    it "validates presence of content" do
      message = build(:chat_message, content: nil)
      expect(message).not_to be_valid
      expect(message.errors[:content]).to include("can't be blank")
    end

    it "validates presence of message_type" do
      message = build(:chat_message, message_type: nil)
      expect(message).not_to be_valid
      expect(message.errors[:message_type]).to include("can't be blank")
    end

    it "validates inclusion of message_type" do
      message = build(:chat_message, message_type: "invalid")
      expect(message).not_to be_valid
      expect(message.errors[:message_type]).to include("is not included in the list")
    end

    it "validates presence of timestamp" do
      message = build(:chat_message, timestamp: nil)
      expect(message).not_to be_valid
      expect(message.errors[:timestamp]).to include("can't be blank")
    end

    it "validates inclusion of profit_impact" do
      message = build(:chat_message, profit_impact: "invalid")
      expect(message).not_to be_valid
      expect(message.errors[:profit_impact]).to include("is not included in the list")
    end

    it "validates presence of relevance_score" do
      message = build(:chat_message, relevance_score: nil)
      expect(message).not_to be_valid
      expect(message.errors[:relevance_score]).to include("can't be blank")
    end

    it "validates numericality of relevance_score" do
      message = build(:chat_message, relevance_score: 0)
      expect(message).not_to be_valid
      expect(message.errors[:relevance_score]).to include("must be greater than 0")

      message.relevance_score = 6
      expect(message).not_to be_valid
      expect(message.errors[:relevance_score]).to include("must be less than or equal to 5")
    end
  end

  describe "associations" do
    it "belongs to chat_session" do
      session = create(:chat_session)
      message = create(:chat_message, chat_session: session)
      expect(message.chat_session).to eq(session)
    end
  end

  describe "enums" do
    it "defines profit_impact enum" do
      message = create(:chat_message, profit_impact: :high)
      expect(message.profit_impact).to eq("high")
      expect(message.high?).to be true
    end

    it "defines message_type enum" do
      message = create(:chat_message, message_type: :bot)
      expect(message.message_type).to eq("bot")
      expect(message.bot?).to be true
    end
  end

  describe "scopes" do
    let(:session) { create(:chat_session) }
    let!(:old_message) { create(:chat_message, chat_session: session, timestamp: 2.hours.ago) }
    let!(:recent_message) { create(:chat_message, chat_session: session, timestamp: 1.hour.ago) }
    let!(:high_profit_message) { create(:chat_message, chat_session: session, profit_impact: :high) }
    let!(:medium_profit_message) { create(:chat_message, chat_session: session, profit_impact: :medium) }
    let!(:low_profit_message) { create(:chat_message, chat_session: session, profit_impact: :low) }
    let!(:user_message) { create(:chat_message, chat_session: session, message_type: :user) }
    let!(:bot_message) { create(:chat_message, chat_session: session, message_type: :bot) }
    let!(:high_relevance_message) { create(:chat_message, chat_session: session, relevance_score: 5.0) }
    let!(:low_relevance_message) { create(:chat_message, chat_session: session, relevance_score: 1.0) }

    describe ".recent" do
      it "orders by timestamp desc" do
        expect(ChatMessage.recent.limit(2)).to eq([recent_message, old_message])
      end
    end

    describe ".profitable" do
      it "returns messages with medium or high profit impact" do
        profitable = ChatMessage.profitable
        expect(profitable).to include(high_profit_message, medium_profit_message)
        expect(profitable).not_to include(low_profit_message)
      end
    end

    describe ".user_messages" do
      it "returns only user messages" do
        expect(ChatMessage.user_messages).to include(user_message)
        expect(ChatMessage.user_messages).not_to include(bot_message)
      end
    end

    describe ".bot_responses" do
      it "returns only bot messages" do
        expect(ChatMessage.bot_responses).to include(bot_message)
        expect(ChatMessage.bot_responses).not_to include(user_message)
      end
    end

    describe ".by_relevance" do
      it "orders by relevance_score desc" do
        expect(ChatMessage.by_relevance.limit(2)).to eq([high_relevance_message, low_relevance_message])
      end
    end
  end

  describe ".for_ai_context" do
    let(:session) { create(:chat_session) }

    before do
      create_list(:chat_message, 30, chat_session: session, profit_impact: :high)
      create_list(:chat_message, 20, chat_session: session, profit_impact: :low)
    end

    it "returns profitable messages limited by token count" do
      result = ChatMessage.for_ai_context(2000)
      expect(result.count).to be <= 50 # Conservative limit
      expect(result.all? { |msg| msg.profit_impact.in?(%w[medium high]) }).to be true
    end

    it "orders by recency" do
      messages = ChatMessage.for_ai_context(4000)
      timestamps = messages.map(&:timestamp)
      expect(timestamps).to eq(timestamps.sort.reverse)
    end
  end

  describe "#trading_related?" do
    let(:session) { create(:chat_session) }

    context "when message has high profit impact" do
      it "returns true" do
        message = create(:chat_message, chat_session: session, profit_impact: :high)
        expect(message.trading_related?).to be true
      end
    end

    context "when message has medium profit impact" do
      it "returns true" do
        message = create(:chat_message, chat_session: session, profit_impact: :medium)
        expect(message.trading_related?).to be true
      end
    end

    context "when message contains trading keywords" do
      it "returns true for position keyword" do
        message = create(:chat_message, chat_session: session, content: "Check my position", profit_impact: :unknown)
        expect(message.trading_related?).to be true
      end

      it "returns true for signal keyword" do
        message = create(:chat_message, chat_session: session, content: "Show signals", profit_impact: :unknown)
        expect(message.trading_related?).to be true
      end

      it "returns true for market keyword" do
        message = create(:chat_message, chat_session: session, content: "Market data", profit_impact: :unknown)
        expect(message.trading_related?).to be true
      end
    end

    context "when message is not trading related" do
      it "returns false" do
        message = create(:chat_message, chat_session: session, content: "Hello world", profit_impact: :unknown)
        expect(message.trading_related?).to be false
      end
    end
  end

  describe "before_validation callback" do
    let(:session) { create(:chat_session) }

    context "when timestamp is blank" do
      it "sets timestamp to current time" do
        message = build(:chat_message, chat_session: session, timestamp: nil)
        expect { message.valid? }.to change { message.timestamp }.from(nil)
        expect(message.timestamp).to be_within(1.second).of(Time.current)
      end
    end

    context "when timestamp is present" do
      it "does not change timestamp" do
        custom_time = 2.hours.ago
        message = build(:chat_message, chat_session: session, timestamp: custom_time)
        message.valid?
        expect(message.timestamp).to be_within(1.second).of(custom_time)
      end
    end
  end
end
