# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatBotService, type: :service do
  let(:session_id) { "test-session-123" }
  let(:service) { described_class.new(session_id) }
  let(:ai_service) { instance_double(AiCommandProcessorService) }
  let(:memory_service) { instance_double(ChatMemoryService) }

  before do
    allow(AiCommandProcessorService).to receive(:new).and_return(ai_service)
    allow(ChatMemoryService).to receive(:new).and_return(memory_service)
    allow(memory_service).to receive(:store)
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
  end

  describe "#initialize" do
    it "creates a new session ID if none provided" do
      service = described_class.new
      expect(service.instance_variable_get(:@session_id)).to be_present
    end

    it "uses provided session ID" do
      expect(service.instance_variable_get(:@session_id)).to eq(session_id)
    end

    it "initializes AI service and memory service" do
      service # Trigger initialization
      expect(AiCommandProcessorService).to have_received(:new)
      expect(ChatMemoryService).to have_received(:new)
    end
  end

  describe "#process" do
    let(:input) { "Show me my positions" }
    let(:ai_response) { {content: "User wants to check their trading positions"} }

    before do
      allow(ai_service).to receive(:process_command).and_return(ai_response)
      allow(Rails.cache).to receive(:fetch).with("trading_active", expires_in: 1.hour).and_return(true)
    end

    context "with valid input" do
      it "processes input successfully" do
        result = service.process(input)
        expect(result).to be_a(String)
        expect(result).to include("Positions Summary")
      end

      it "stores interaction in memory" do
        service.process(input)
        expect(memory_service).to have_received(:store_user_input).with(input)
      end

      it "calls AI service with context" do
        service.process(input)
        expect(ai_service).to have_received(:process_command).with(input, context: hash_including(:session_id))
      end
    end

    context "with invalid input" do
      it "handles empty input" do
        result = service.process("")
        expect(result).to include("Invalid input")
      end

      it "sanitizes malicious input" do
        malicious_input = "<script>alert('xss')</script>show positions"
        result = service.process(malicious_input)
        expect(result).to be_a(String)
      end
    end

    context "when AI service fails" do
      before do
        allow(ai_service).to receive(:process_command).and_raise(StandardError, "AI service down")
      end

      it "handles AI service errors gracefully" do
        result = service.process(input)
        expect(result).to include("Processing failed")
      end
    end
  end

  describe "command execution" do
    before do
      allow(ai_service).to receive(:process_command).and_return({content: "position query"})
      allow(Rails.cache).to receive(:fetch).with("trading_active", expires_in: 1.hour).and_return(true)
    end

    describe "position queries" do
      let(:position) do
        create(:position, product_id: "BTC-PERP", side: "LONG", size: 1.0, entry_price: 50_000, status: "OPEN")
      end

      before do
        position
        allow(ai_service).to receive(:process_command).and_return({content: "position pnl check"})
      end

      it "returns position summary" do
        result = service.process("show positions")
        expect(result).to include("Positions Summary")
        expect(result).to include("Open: 1")
      end
    end

    describe "signal queries" do
      let(:signal) { create(:signal_alert, symbol: "BTC-PERP", confidence: 85, alert_status: "active") }

      before do
        signal
        allow(ai_service).to receive(:process_command).and_return({content: "signal alert check"})
      end

      it "returns signal summary" do
        result = service.process("show signals")
        expect(result).to include("Signal Summary")
        expect(result).to include("Active Signals: 1")
      end
    end

    describe "market data queries" do
      let(:candle) { create(:candle, symbol: "BTC-PERP", close: 51_000.50, timestamp: 1.minute.ago) }

      before do
        candle
        allow(ai_service).to receive(:process_command).and_return({content: "market data btc"})
      end

      it "returns market data" do
        result = service.process("btc price")
        expect(result).to include("Market Data")
        expect(result).to include("BTC-PERP")
      end
    end

    describe "system status queries" do
      before do
        allow(ai_service).to receive(:process_command).and_return({content: "system status health"})
        allow(service).to receive(:application_uptime).and_return("1h")
      end

      it "returns system status" do
        result = service.process("system status")
        expect(result).to include("System Status")
        expect(result).to include("Active")
      end
    end

    describe "help queries" do
      before do
        allow(ai_service).to receive(:process_command).and_return({content: "help commands what"})
      end

      it "returns help information" do
        result = service.process("help")
        expect(result).to include("Available Commands")
        expect(result).to include("Check positions")
      end
    end
  end

  describe "#session_summary" do
    it "returns session summary from memory service" do
      expected_summary = {
        session_id: session_id,
        total_interactions: 5,
        last_activity: "2025-01-01T12:00:00Z",
        command_types: %w[position_query signal_query]
      }

      allow(memory_service).to receive(:session_summary).and_return(expected_summary)

      result = service.session_summary
      expect(result).to eq(expected_summary)
    end
  end

  describe "response formatting" do
    let(:position_data) do
      {
        type: "position_data",
        data: {
          open_positions: 2,
          day_trading: 1,
          swing_trading: 1,
          total_pnl: 150.50,
          positions: [
            {symbol: "BTC-PERP", side: "LONG", size: 1.0, entry_price: 50_000.0, pnl: "$75.25"}
          ]
        }
      }
    end

    it "formats position responses correctly" do
      formatted = service.send(:format_response, position_data, {type: "position_query"})
      expect(formatted).to include("\u{1F4CA} Positions Summary")
      expect(formatted).to include("Open: 2")
      expect(formatted).to include("Total PnL: $150.5")
      expect(formatted).to include("LONG 1.0 BTC-PERP")
    end

    it "formats error responses correctly" do
      error_data = {type: "error", message: "Something went wrong"}
      formatted = service.send(:format_response, error_data, {})
      expect(formatted).to eq("\u274C Something went wrong")
    end
  end

  describe "input sanitization" do
    it "removes dangerous characters" do
      dangerous_input = "<script>alert('xss')</script>show positions"
      sanitized = service.send(:sanitize_input, dangerous_input)
      expect(sanitized).not_to include("<script>")
      expect(sanitized).to include("show positions")
    end

    it "truncates long input" do
      long_input = "a" * 1000
      sanitized = service.send(:sanitize_input, long_input)
      expect(sanitized.length).to eq(500)
    end

    it "handles nil input" do
      sanitized = service.send(:sanitize_input, nil)
      expect(sanitized).to eq("")
    end
  end

  describe "parameter extraction" do
    it "extracts symbol from position queries" do
      content = "show btc-perp position data"
      params = service.send(:extract_position_params, content)
      expect(params[:symbol]).to eq("BTC-PERP")
    end

    it "extracts symbol from market queries" do
      content = "get eth price data"
      params = service.send(:extract_market_params, content)
      expect(params[:symbol]).to eq("ETH-PERP")
    end

    it "defaults to BTC-PERP for market queries without symbol" do
      content = "show market data"
      params = service.send(:extract_market_params, content)
      expect(params[:symbol]).to eq("BTC-PERP")
    end
  end

  describe "context building" do
    let(:trading_context) do
      {
        active: true,
        day_positions: 2,
        swing_positions: 1
      }
    end

    before do
      allow(service).to receive(:trading_status_context).and_return(trading_context)
      allow(service).to receive(:market_context).and_return({recent_signals: 3})
    end

    it "builds comprehensive context for AI" do
      context = service.send(:build_context)

      expect(context).to include(:session_id)
      expect(context).to include(:recent_interactions)
      expect(context).to include(:trading_status)
      expect(context).to include(:market_context)
      expect(context[:session_id]).to eq(session_id)
      expect(context[:trading_status]).to eq(trading_context)
    end
  end
end
