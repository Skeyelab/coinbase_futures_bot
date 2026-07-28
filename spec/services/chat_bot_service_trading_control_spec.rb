# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatBotService, type: :service do
  let(:session_id) { "test-session-trading-123" }
  let(:service) { described_class.new(session_id) }
  let(:ai_service) { instance_double(AiCommandProcessorService) }
  let(:memory_service) { instance_double(ChatMemoryService) }

  before do
    allow(AiCommandProcessorService).to receive(:new).and_return(ai_service)
    allow(ChatMemoryService).to receive(:new).and_return(memory_service)
    allow(memory_service).to receive(:store_user_input)
    allow(memory_service).to receive(:store_bot_response)
    allow(memory_service).to receive(:context_for_ai).and_return("test context")
    allow(memory_service).to receive(:recent_interactions).and_return([])
    allow(memory_service).to receive(:session_summary).and_return({
      session_id: session_id,
      total_interactions: 0,
      last_activity: nil,
      command_types: []
    })

    # Clear cache before each test
    Rails.cache.clear
  end

  # Chat is READ-ONLY with respect to trading state. POST /api/chat_messages is
  # unauthenticated, and intent is matched by regex over the *model's own
  # response* (parse_ai_response cases on `content`), so any prompt that induces
  # the model to echo "emergency stop" fired the real thing.
  describe "trading state is not mutable from chat" do
    def ai_says(content)
      allow(ai_service).to receive(:process_command).and_return({content: content})
    end

    it "does not halt trading when asked to stop" do
      ai_says("stop trading operations pause")
      TradingHalt.resume!

      service.process("stop trading")

      expect(TradingHalt.active?).to be(true)
    end

    it "does not resume trading when asked to start" do
      ai_says("start trading operations now")
      TradingHalt.halt!(reason: "operator paused")

      service.process("start trading")

      expect(TradingHalt.active?).to be(false)
      expect(TradingHalt.status[:reason]).to eq("operator paused")
    end

    # The old emergency stop halted trading, then reported a count of positions
    # it had not closed (`position.close!` was commented out). Halting while
    # claiming the book is flat is the dangerous half: the operator reads
    # "flat" and walks away from open leveraged positions.
    it "does not claim to have closed positions it left open" do
      ai_says("emergency stop kill switch")
      TradingHalt.resume!
      create_list(:position, 2, product_id: "BTC-USD")

      result = service.process("emergency stop")

      expect(result).not_to include("Positions closed")
      expect(result).not_to include("EMERGENCY STOP EXECUTED")
      expect(Position.open.count).to eq(2)
      expect(TradingHalt.active?).to be(true)
    end
  end

  describe "trading control commands" do
    describe "start trading command" do
      let(:ai_response) { {content: "start trading operations now"} }

      before do
        allow(ai_service).to receive(:process_command).and_return(ai_response)
      end

      it "declines and names the surfaces that can act" do
        result = service.process("start trading")

        expect(result).to include("Chat cannot change trading state")
        expect(result).to include("bin/futuresbot")
      end
    end

    describe "position sizing command" do
      let(:ai_response) { {content: "show position sizing configuration"} }

      before do
        allow(ai_service).to receive(:process_command).and_return(ai_response)
        allow(ENV).to receive(:fetch).with("SIGNAL_EQUITY_USD", "10000").and_return("25000")
        allow(ENV).to receive(:fetch).with("RISK_PER_TRADE_PERCENT", "2").and_return("1.5")
      end

      it "returns position sizing information" do
        result = service.process("position sizing")

        expect(result).to include("📊 Position Sizing Configuration")
        expect(result).to include("Equity: $25000.0")
        expect(result).to include("Risk per trade: 1.5%")
        expect(result).to include("Max risk per trade: $375.0")
        expect(result).to include("SIGNAL_EQUITY_USD")
        expect(result).to include("RISK_PER_TRADE_PERCENT")
      end
    end
  end

  describe "trading control command parsing" do
    before do
      allow(memory_service).to receive(:store_user_input)
      allow(memory_service).to receive(:store_bot_response)
    end

    it "recognizes start trading patterns" do
      patterns = [
        "start trading",
        "resume trading operations",
        "enable trading",
        "trading start"
      ]

      patterns.each do |pattern|
        allow(ai_service).to receive(:process_command).and_return({content: pattern})
        result = service.send(:parse_ai_response, {content: pattern})
        expect(result[:type]).to eq("trading_control")
        expect(result[:params][:action]).to eq("start")
      end
    end

    it "recognizes stop trading patterns" do
      patterns = [
        "stop trading",
        "pause trading operations",
        "disable trading",
        "trading stop"
      ]

      patterns.each do |pattern|
        allow(ai_service).to receive(:process_command).and_return({content: pattern})
        result = service.send(:parse_ai_response, {content: pattern})
        expect(result[:type]).to eq("trading_control")
        expect(result[:params][:action]).to eq("stop")
      end
    end

    it "recognizes emergency stop patterns" do
      patterns = [
        "emergency stop",
        "kill switch",
        "stop emergency"
      ]

      patterns.each do |pattern|
        allow(ai_service).to receive(:process_command).and_return({content: pattern})
        result = service.send(:parse_ai_response, {content: pattern})
        expect(result[:type]).to eq("trading_control")
        expect(result[:params][:action]).to eq("emergency_stop")
      end
    end

    it "recognizes position sizing patterns" do
      patterns = [
        "position size",
        "sizing position",
        "position sizing"
      ]

      patterns.each do |pattern|
        allow(ai_service).to receive(:process_command).and_return({content: pattern})
        result = service.send(:parse_ai_response, {content: pattern})
        expect(result[:type]).to eq("trading_control")
        expect(result[:params][:action]).to eq("position_sizing")
      end
    end
  end

  describe "trading status helpers" do
    describe "#trading_active?" do
      it "returns true by default" do
        expect(service.send(:trading_active?)).to be(true)
      end

      it "reflects a halt written by another surface" do
        TradingHalt.halt!(reason: "halted from the CLI")

        expect(service.send(:trading_active?)).to be(false)
      end
    end
  end
end
