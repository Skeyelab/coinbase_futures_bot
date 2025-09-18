# frozen_string_literal: true

require "rails_helper"
require "climate_control"

RSpec.describe AiCommandProcessorService, type: :service do
  let(:service) { described_class.new }
  let(:test_input) { "What is the current market trend for BTC?" }
  let(:test_context) { {symbol: "BTC-USD", timeframe: "1h"} }

  describe "#initialize" do
    context "with valid API keys" do
      it "initializes successfully with OpenRouter key" do
        ClimateControl.modify(OPENROUTER_API_KEY: "test_key", OPENAI_API_KEY: nil) do
          expect { described_class.new }.not_to raise_error
        end
      end

      it "initializes successfully with OpenAI key" do
        ClimateControl.modify(OPENROUTER_API_KEY: nil, OPENAI_API_KEY: "test_key") do
          expect { described_class.new }.not_to raise_error
        end
      end

      it "initializes successfully with both keys" do
        ClimateControl.modify(OPENROUTER_API_KEY: "openrouter_key", OPENAI_API_KEY: "openai_key") do
          expect { described_class.new }.not_to raise_error
        end
      end
    end

    context "without API keys" do
      it "raises ConfigurationError when no keys are provided" do
        ClimateControl.modify(OPENROUTER_API_KEY: nil, OPENAI_API_KEY: nil) do
          expect { described_class.new }.to raise_error(AiCommandProcessorService::ConfigurationError)
        end
      end

      it "raises ConfigurationError when keys are empty strings" do
        ClimateControl.modify(OPENROUTER_API_KEY: "", OPENAI_API_KEY: "") do
          expect { described_class.new }.to raise_error(AiCommandProcessorService::ConfigurationError)
        end
      end
    end
  end

  describe "#process_command", :vcr do
    context "with OpenRouter available" do
      before do
        allow(ENV).to receive(:[]).with("OPENROUTER_API_KEY").and_return("test_openrouter_key")
        allow(ENV).to receive(:[]).with("OPENAI_API_KEY").and_return(nil)
      end

      it "processes command successfully via OpenRouter" do
        VCR.use_cassette("ai_service/openrouter_success") do
          result = service.process_command(test_input, context: test_context)

          expect(result).to be_a(Hash)
          expect(result[:content]).to be_present
          expect(result[:provider]).to eq("openrouter")
          expect(result[:model]).to be_present
        end
      end

      it "includes usage information in response" do
        VCR.use_cassette("ai_service/openrouter_with_usage") do
          result = service.process_command(test_input)

          expect(result[:usage]).to be_present
          expect(result[:usage]).to include("prompt_tokens", "completion_tokens", "total_tokens")
        end
      end

      it "handles long input by truncating" do
        long_input = "a" * 5000
        VCR.use_cassette("ai_service/openrouter_long_input") do
          expect { service.process_command(long_input) }.not_to raise_error
        end
      end
    end

    context "with OpenAI available" do
      before do
        allow(ENV).to receive(:[]).with("OPENROUTER_API_KEY").and_return(nil)
        allow(ENV).to receive(:[]).with("OPENAI_API_KEY").and_return("test_openai_key")
      end

      it "processes command successfully via OpenAI" do
        VCR.use_cassette("ai_service/openai_success") do
          result = service.process_command(test_input, context: test_context)

          expect(result).to be_a(Hash)
          expect(result[:content]).to be_present
          expect(result[:provider]).to eq("openai")
          expect(result[:model]).to be_present
        end
      end
    end

    context "with fallback behavior" do
      before do
        allow(ENV).to receive(:[]).with("OPENROUTER_API_KEY").and_return("test_openrouter_key")
        allow(ENV).to receive(:[]).with("OPENAI_API_KEY").and_return("test_openai_key")
      end

      it "falls back to OpenAI when OpenRouter fails" do
        # Mock OpenRouter failure
        allow(service).to receive(:call_openrouter).and_raise(AiCommandProcessorService::ApiError.new("OpenRouter failed"))

        VCR.use_cassette("ai_service/fallback_to_openai") do
          result = service.process_command(test_input)

          expect(result[:provider]).to eq("openai")
        end
      end

      it "raises error when both services fail" do
        allow(service).to receive(:call_openrouter).and_raise(AiCommandProcessorService::ApiError.new("OpenRouter failed"))
        allow(service).to receive(:call_chatgpt).and_raise(AiCommandProcessorService::ApiError.new("OpenAI failed"))

        expect { service.process_command(test_input) }.to raise_error(AiCommandProcessorService::ApiError, /All AI services failed/)
      end
    end

    context "with custom model preferences" do
      before do
        allow(ENV).to receive(:[]).with("OPENROUTER_API_KEY").and_return("test_openrouter_key")
        allow(ENV).to receive(:[]).with("OPENAI_API_KEY").and_return(nil)
      end

      it "uses custom model when specified" do
        custom_model = "anthropic/claude-3-haiku"
        VCR.use_cassette("ai_service/custom_model") do
          result = service.process_command(test_input, model_preference: custom_model)

          expect(result[:model]).to eq(custom_model)
        end
      end
    end
  end

  describe "#call_openrouter", :vcr do
    before do
      allow(ENV).to receive(:[]).with("OPENROUTER_API_KEY").and_return("test_openrouter_key")
      allow(ENV).to receive(:[]).with("OPENAI_API_KEY").and_return(nil)
    end

    it "makes successful API call" do
      VCR.use_cassette("ai_service/openrouter_direct_call") do
        result = service.call_openrouter(test_input)

        expect(result).to include(:content, :model, :usage, :provider)
        expect(result[:provider]).to eq("openrouter")
      end
    end

    it "handles API errors gracefully" do
      VCR.use_cassette("ai_service/openrouter_api_error") do
        expect { service.call_openrouter("") }.to raise_error(AiCommandProcessorService::ApiError)
      end
    end

    it "includes proper headers in request" do
      expect_any_instance_of(Faraday::Connection).to receive(:post).with("/chat/completions") do |&block|
        req = double("request")
        expect(req).to receive(:headers=).with(hash_including(
          "Authorization" => "Bearer test_openrouter_key",
          "Content-Type" => "application/json",
          "HTTP-Referer" => anything,
          "X-Title" => "Coinbase Futures Bot"
        ))
        expect(req).to receive(:body=)
        block&.call(req)
        double("response", body: '{"choices":[{"message":{"content":"test"}}],"model":"test","usage":{}}')
      end

      service.call_openrouter(test_input)
    end
  end

  describe "#call_chatgpt", :vcr do
    before do
      allow(ENV).to receive(:[]).with("OPENROUTER_API_KEY").and_return(nil)
      allow(ENV).to receive(:[]).with("OPENAI_API_KEY").and_return("test_openai_key")
    end

    it "makes successful API call" do
      VCR.use_cassette("ai_service/chatgpt_direct_call") do
        result = service.call_chatgpt(test_input)

        expect(result).to include(:content, :model, :usage, :provider)
        expect(result[:provider]).to eq("openai")
      end
    end

    it "handles API errors gracefully" do
      VCR.use_cassette("ai_service/chatgpt_api_error") do
        expect { service.call_chatgpt("") }.to raise_error(AiCommandProcessorService::ApiError)
      end
    end
  end

  describe "#available_models", :vcr do
    before do
      allow(ENV).to receive(:[]).with("OPENROUTER_API_KEY").and_return("test_openrouter_key")
      allow(ENV).to receive(:[]).with("OPENAI_API_KEY").and_return(nil)
    end

    it "fetches available models from OpenRouter" do
      VCR.use_cassette("ai_service/available_models") do
        models = service.available_models

        expect(models).to be_an(Array)
        expect(models.first).to include("id", "name")
      end
    end

    it "returns empty array when API call fails" do
      VCR.use_cassette("ai_service/models_api_error") do
        models = service.available_models

        expect(models).to eq([])
      end
    end
  end

  describe "#healthy?" do
    context "with valid configuration" do
      before do
        allow(ENV).to receive(:[]).with("OPENROUTER_API_KEY").and_return("test_key")
        allow(ENV).to receive(:[]).with("OPENAI_API_KEY").and_return(nil)
      end

      it "returns true when service is healthy" do
        allow(service).to receive(:process_command).and_return({content: "Hello"})

        expect(service.healthy?).to be true
      end

      it "returns false when service fails" do
        allow(service).to receive(:process_command).and_raise(StandardError)

        expect(service.healthy?).to be false
      end
    end

    context "without API keys" do
      before do
        allow(ENV).to receive(:[]).with("OPENROUTER_API_KEY").and_return(nil)
        allow(ENV).to receive(:[]).with("OPENAI_API_KEY").and_return(nil)
      end

      it "returns false" do
        service_instance = described_class.allocate # Create without initialize
        allow(service_instance).to receive(:instance_variable_get).with(:@openrouter_api_key).and_return(nil)
        allow(service_instance).to receive(:instance_variable_get).with(:@openai_api_key).and_return(nil)

        expect(service_instance.healthy?).to be false
      end
    end
  end

  describe "error handling" do
    before do
      allow(ENV).to receive(:[]).with("OPENROUTER_API_KEY").and_return("test_key")
      allow(ENV).to receive(:[]).with("OPENAI_API_KEY").and_return(nil)
    end

    describe "timeout handling" do
      it "handles connection timeouts with retry" do
        allow_any_instance_of(Faraday::Connection).to receive(:post)
          .and_raise(Faraday::TimeoutError.new("timeout"))
          .exactly(3).times

        expect { service.call_openrouter(test_input) }.to raise_error(AiCommandProcessorService::ApiError, /timeout/)
      end

      it "retries on connection failures" do
        allow_any_instance_of(Faraday::Connection).to receive(:post)
          .and_raise(Faraday::ConnectionFailed.new("connection failed"))
          .exactly(3).times

        expect { service.call_openrouter(test_input) }.to raise_error(AiCommandProcessorService::ApiError, /connection failed/)
      end
    end

    describe "HTTP error handling" do
      it "doesn't retry on 4xx client errors" do
        error = Faraday::ClientError.new("Bad request", {status: 400, body: "Bad request"})
        allow_any_instance_of(Faraday::Connection).to receive(:post).and_raise(error)

        expect { service.call_openrouter(test_input) }.to raise_error(AiCommandProcessorService::ApiError, /client error/)
      end

      it "retries on 5xx server errors" do
        error = Faraday::ServerError.new("Server error", {status: 500, body: "Server error"})
        allow_any_instance_of(Faraday::Connection).to receive(:post)
          .and_raise(error)
          .exactly(3).times

        expect { service.call_openrouter(test_input) }.to raise_error(AiCommandProcessorService::ApiError, /Server error/)
      end
    end
  end

  describe "input sanitization" do
    before do
      allow(ENV).to receive(:[]).with("OPENROUTER_API_KEY").and_return("test_key")
      allow(ENV).to receive(:[]).with("OPENAI_API_KEY").and_return(nil)
    end

    it "trims whitespace from input" do
      expect(service.send(:sanitize_input, "  test input  ")).to eq("test input")
    end

    it "limits input length" do
      long_input = "a" * 5000
      sanitized = service.send(:sanitize_input, long_input)
      expect(sanitized.length).to eq(4000)
    end

    it "handles nil input" do
      expect(service.send(:sanitize_input, nil)).to eq("")
    end
  end

  describe "message building" do
    before do
      allow(ENV).to receive(:[]).with("OPENROUTER_API_KEY").and_return("test_key")
      allow(ENV).to receive(:[]).with("OPENAI_API_KEY").and_return(nil)
    end

    it "builds messages with system context" do
      messages = service.send(:build_messages, test_input, context: test_context)

      expect(messages).to be_an(Array)
      expect(messages.length).to eq(2)
      expect(messages[0][:role]).to eq("system")
      expect(messages[1][:role]).to eq("user")
      expect(messages[1][:content]).to eq(test_input)
    end

    it "includes context in system message" do
      messages = service.send(:build_messages, test_input, context: {symbol: "BTC-USD"})
      system_message = messages[0][:content]

      expect(system_message).to include("symbol: BTC-USD")
    end

    it "works without context" do
      messages = service.send(:build_messages, test_input)

      expect(messages.length).to eq(2)
      expect(messages[0][:role]).to eq("system")
    end
  end

  describe "response parsing" do
    before do
      allow(ENV).to receive(:[]).with("OPENROUTER_API_KEY").and_return("test_key")
      allow(ENV).to receive(:[]).with("OPENAI_API_KEY").and_return(nil)
    end

    describe "OpenRouter response parsing" do
      it "parses successful response" do
        response_body = {
          "choices" => [{"message" => {"content" => "Test response"}}],
          "model" => "test-model",
          "usage" => {"total_tokens" => 100}
        }.to_json
        response = double("response", body: response_body, status: 200)

        result = service.send(:parse_openrouter_response, response)

        expect(result[:content]).to eq("Test response")
        expect(result[:model]).to eq("test-model")
        expect(result[:provider]).to eq("openrouter")
      end

      it "handles API error response" do
        response_body = {
          "error" => {"message" => "API error"}
        }.to_json
        response = double("response", body: response_body, status: 400)

        expect { service.send(:parse_openrouter_response, response) }
          .to raise_error(AiCommandProcessorService::ApiError, /OpenRouter API error/)
      end

      it "handles malformed response" do
        response_body = {"invalid" => "response"}.to_json
        response = double("response", body: response_body, status: 200)

        expect { service.send(:parse_openrouter_response, response) }
          .to raise_error(AiCommandProcessorService::ApiError, /Invalid response format/)
      end
    end

    describe "ChatGPT response parsing" do
      it "parses successful response" do
        response_body = {
          "choices" => [{"message" => {"content" => "Test response"}}],
          "model" => "gpt-4",
          "usage" => {"total_tokens" => 100}
        }.to_json
        response = double("response", body: response_body, status: 200)

        result = service.send(:parse_chatgpt_response, response)

        expect(result[:content]).to eq("Test response")
        expect(result[:model]).to eq("gpt-4")
        expect(result[:provider]).to eq("openai")
      end
    end
  end

  describe "Sentry integration" do
    before do
      allow(ENV).to receive(:[]).with("OPENROUTER_API_KEY").and_return("test_key")
      allow(ENV).to receive(:[]).with("OPENAI_API_KEY").and_return(nil)
    end

    it "tracks service calls" do
      expect(service).to receive(:track_service_call).with("process_command", anything)

      allow(service).to receive(:call_openrouter).and_return({content: "test", provider: "openrouter"})
      service.process_command(test_input)
    end

    it "tracks external API calls" do
      expect(service).to receive(:track_external_api_call).with("openrouter", "/chat/completions", "process_command", anything)

      allow_any_instance_of(Faraday::Connection).to receive(:post).and_return(
        double("response", body: '{"choices":[{"message":{"content":"test"}}],"model":"test","usage":{}}')
      )
      service.call_openrouter(test_input)
    end
  end
end
