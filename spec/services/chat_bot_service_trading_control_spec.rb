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

  describe "trading control commands" do
    describe "start trading command" do
      let(:ai_response) { {content: "start trading operations now"} }

      before do
        allow(ai_service).to receive(:process_command).and_return(ai_response)
      end

      context "when trading is currently inactive" do
        before do
          Rails.cache.write("trading_active", false)
        end

        it "activates trading and returns success message" do
          result = service.process("start trading")

          expect(result).to include("✅ Trading has been activated")
          expect(Rails.cache.read("trading_active")).to be(true)
        end
      end

      context "when trading is already active" do
        before do
          Rails.cache.write("trading_active", true)
        end

        it "returns already active message" do
          result = service.process("start trading")

          expect(result).to include("Trading is already active")
          expect(Rails.cache.read("trading_active")).to be(true)
        end
      end
    end

    describe "stop trading command" do
      let(:ai_response) { {content: "stop trading operations pause"} }

      before do
        allow(ai_service).to receive(:process_command).and_return(ai_response)
      end

      context "when trading is currently active" do
        before do
          Rails.cache.write("trading_active", true)
        end

        it "pauses trading and returns success message" do
          result = service.process("stop trading")

          expect(result).to include("⏸️ Trading has been paused")
          expect(Rails.cache.read("trading_active")).to be(false)
        end
      end

      context "when trading is already inactive" do
        before do
          Rails.cache.write("trading_active", false)
        end

        it "returns already inactive message" do
          result = service.process("stop trading")

          expect(result).to include("Trading is already inactive")
          expect(Rails.cache.read("trading_active")).to be(false)
        end
      end
    end

    describe "emergency stop command" do
      let(:ai_response) { {content: "emergency stop kill switch"} }

      before do
        allow(ai_service).to receive(:process_command).and_return(ai_response)
        # Mock Position model
        allow(Position).to receive_message_chain(:open, :day_trading).and_return([])
        allow(Position).to receive_message_chain(:open, :swing_trading).and_return([])
      end

      it "executes emergency stop and returns detailed message" do
        result = service.process("emergency stop")

        expect(result).to include("🚨 EMERGENCY STOP EXECUTED 🚨")
        expect(result).to include("Positions closed: 0")
        expect(result).to include("Orders cancelled: 0")
        expect(Rails.cache.read("trading_active")).to be(false)
        expect(Rails.cache.read("emergency_stop")).to be(true)
      end

      context "with open positions" do
        let(:mock_position1) { instance_double(Position, product_id: "BTC-PERP") }
        let(:mock_position2) { instance_double(Position, product_id: "ETH-PERP") }

        before do
          allow(Position).to receive_message_chain(:open, :day_trading).and_return([mock_position1, mock_position2])
        end

        it "counts positions to be closed" do
          result = service.process("emergency stop")

          expect(result).to include("Positions closed: 2")
        end
      end
    end

    describe "position sizing command" do
      let(:ai_response) { {content: "show position sizing configuration"} }

      before do
        allow(ai_service).to receive(:process_command).and_return(ai_response)
        allow(ENV).to receive(:fetch).with("SIGNAL_EQUITY_USD", "10000").and_return("25000")
        allow(ENV).to receive(:fetch).with("RISK_PER_TRADE_PERCENT", "2").and_return("1.5")
        # Mock Position model
        allow(Position).to receive_message_chain(:open, :day_trading).and_return([])
        allow(Position).to receive_message_chain(:open, :swing_trading).and_return([])
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

      it "returns cached status when set" do
        service.send(:set_trading_status, false)
        expect(service.send(:trading_active?)).to be(false)
      end
    end

    describe "#set_trading_status" do
      it "sets trading status in cache" do
        service.send(:set_trading_status, false)
        expect(Rails.cache.read("trading_active")).to be(false)
      end

      it "sets emergency flag when specified" do
        service.send(:set_trading_status, false, emergency: true)
        expect(Rails.cache.read("emergency_stop")).to be(true)
      end
    end
  end
end
