# frozen_string_literal: true

require "rails_helper"
require "climate_control"

RSpec.describe AiCommandProcessorService, type: :service do
  let(:service) { described_class.new }
  let(:test_input) { "What is the current BTC trend?" }

  describe "#initialize" do
    it "requires at least one API key" do
      ClimateControl.modify(OPENROUTER_API_KEY: nil, OPENAI_API_KEY: nil) do
        expect { described_class.new }.to raise_error(AiCommandProcessorService::ConfigurationError)
      end
    end

    it "works with either API key" do
      ClimateControl.modify(OPENROUTER_API_KEY: "test", OPENAI_API_KEY: nil) do
        expect { described_class.new }.not_to raise_error
      end
    end
  end

  describe "#process_command" do
    before do
      allow(ENV).to receive(:[]).with("OPENROUTER_API_KEY").and_return("test_key")
      allow(ENV).to receive(:[]).with("OPENAI_API_KEY").and_return(nil)
    end

    it "processes command successfully" do
      # Mock successful response
      mock_response = double("response", body: {
        "choices" => [{"message" => {"content" => "Test response"}}],
        "model" => "test-model",
        "usage" => {"total_tokens" => 100}
      }.to_json)

      allow_any_instance_of(Faraday::Connection).to receive(:post).and_return(mock_response)

      result = service.process_command(test_input)

      expect(result[:content]).to eq("Test response")
      expect(result[:provider]).to eq("openrouter")
    end

    it "falls back to OpenAI when OpenRouter fails" do
      allow(ENV).to receive(:[]).with("OPENAI_API_KEY").and_return("test_openai_key")
      allow(service).to receive(:call_openrouter).and_raise(AiCommandProcessorService::ApiError)
      allow(service).to receive(:call_chatgpt).and_return({content: "fallback", provider: "openai"})

      result = service.process_command(test_input)
      expect(result[:provider]).to eq("openai")
    end
  end

  describe "#call_openrouter" do
    before do
      allow(ENV).to receive(:[]).with("OPENROUTER_API_KEY").and_return("test_key")
    end

    it "raises error without API key" do
      service.instance_variable_set(:@openrouter_key, nil)
      expect do
        service.call_openrouter(test_input)
      end.to raise_error(AiCommandProcessorService::ApiError, /not configured/)
    end
  end

  describe "#healthy?" do
    before do
      allow(ENV).to receive(:[]).with("OPENROUTER_API_KEY").and_return("test_key")
      allow(ENV).to receive(:[]).with("OPENAI_API_KEY").and_return(nil)
    end

    it "returns true when service works" do
      allow(service).to receive(:process_command).and_return({content: "test"})
      expect(service.healthy?).to be true
    end

    it "returns false when service fails" do
      allow(service).to receive(:process_command).and_raise(StandardError)
      expect(service.healthy?).to be false
    end
  end

  describe "private methods" do
    before do
      allow(ENV).to receive(:[]).with("OPENROUTER_API_KEY").and_return("test_key")
    end

    describe "#system_message" do
      it "builds basic system message" do
        message = service.send(:system_message, {})
        expect(message).to include("Coinbase futures trading bot")
      end

      it "includes context when provided" do
        message = service.send(:system_message, {symbol: "BTC"})
        expect(message).to include("symbol: BTC")
      end
    end

    describe "#parse_response" do
      it "parses successful response" do
        response = double("response", body: {
          "choices" => [{"message" => {"content" => "Test response"}}],
          "model" => "test-model",
          "usage" => {"total_tokens" => 100}
        }.to_json)

        result = service.send(:parse_response, response, "test")
        expect(result[:content]).to eq("Test response")
        expect(result[:provider]).to eq("test")
      end

      it "handles error response" do
        response = double("response", body: {"error" => {"message" => "API error"}}.to_json)
        expect { service.send(:parse_response, response, "test") }
          .to raise_error(AiCommandProcessorService::ApiError, /API error/)
      end
    end
  end
end
