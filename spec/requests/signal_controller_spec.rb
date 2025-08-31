# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Signals API", type: :request do
  let(:api_key) { "test_api_key_123" }
  let(:trading_pair) { create(:trading_pair, product_id: "BTC-USD") }
  let(:signal_alert) { create(:signal_alert, symbol: "BTC-USD") }
  let(:real_time_evaluator) { instance_double(RealTimeSignalEvaluator) }

  before do
    # Set up API key environment
    @original_api_key = ENV["SIGNALS_API_KEY"]
    ENV["SIGNALS_API_KEY"] = api_key

    # Mock Sentry components to avoid noise in tests
    allow(SentryHelper).to receive(:add_breadcrumb)

    # Use spy for permissive mocking of Sentry scope
    sentry_scope = spy("Sentry::Scope")
    allow(Sentry).to receive(:with_scope).and_yield(sentry_scope)
    allow(Sentry).to receive(:capture_message)
    allow(Sentry).to receive(:capture_exception)

    # Mock RealTimeSignalEvaluator
    allow(RealTimeSignalEvaluator).to receive(:new).and_return(real_time_evaluator)
    allow(real_time_evaluator).to receive(:evaluate_pair)
    allow(real_time_evaluator).to receive(:evaluate_all_pairs)
  end

  after do
    ENV["SIGNALS_API_KEY"] = @original_api_key
  end

  describe "authentication" do
    context "when API key is required" do
      it "rejects requests without API key" do
        get "/signals"
        expect(response).to have_http_status(:unauthorized)
        expect(JSON.parse(response.body)).to eq({"error" => "Unauthorized"})
      end

      it "rejects requests with invalid API key" do
        get "/signals", headers: {"X-API-Key" => "invalid_key"}
        expect(response).to have_http_status(:unauthorized)
        expect(JSON.parse(response.body)).to eq({"error" => "Unauthorized"})
      end

      it "accepts requests with valid API key in header" do
        get "/signals", headers: {"X-API-Key" => api_key}
        expect(response).to have_http_status(:success)
      end

      it "accepts requests with valid API key in params" do
        get "/signals", params: {api_key: api_key}
        expect(response).to have_http_status(:success)
      end
    end

    context "when no API key is configured" do
      before do
        ENV["SIGNALS_API_KEY"] = nil
      end

      it "allows all requests when no API key is set" do
        get "/signals"
        expect(response).to have_http_status(:success)
      end
    end

    context "health endpoint" do
      it "does not require authentication" do
        get "/signals/health"
        expect(response).to have_http_status(:success)
      end
    end
  end

  describe "CORS headers" do
    before do
      get "/signals", headers: {"X-API-Key" => api_key}
    end

    it "sets CORS headers on all responses" do
      expect(response.headers["Access-Control-Allow-Origin"]).to eq("*")
      expect(response.headers["Access-Control-Allow-Methods"]).to eq("GET, POST, PUT, DELETE, OPTIONS")
      expect(response.headers["Access-Control-Allow-Headers"]).to eq("Content-Type, X-API-Key")
    end
  end

  describe "GET /signals" do
    before do
      @headers = {"X-API-Key" => api_key}
    end

    context "with no signals" do
      it "returns empty results with pagination meta" do
        get "/signals", headers: @headers

        expect(response).to have_http_status(:success)
        json_response = JSON.parse(response.body)
        expect(json_response["signals"]).to eq([])
        expect(json_response["meta"]).to include(
          "total_count" => 0,
          "current_page" => 1,
          "per_page" => 50,
          "total_pages" => 0
        )
      end
    end

    context "with signals" do
      let!(:active_signal) { create(:signal_alert, symbol: "BTC-USD", confidence: 80, alert_status: "active") }
      let!(:triggered_signal) { create(:signal_alert, :triggered, symbol: "ETH-USD", confidence: 90) }
      let!(:expired_signal) { create(:signal_alert, :expired, symbol: "BTC-USD") }

      it "returns only active signals ordered by confidence and timestamp" do
        get "/signals", headers: @headers

        expect(response).to have_http_status(:success)
        json_response = JSON.parse(response.body)
        expect(json_response["signals"].length).to eq(1)
        expect(json_response["signals"][0]["id"]).to eq(active_signal.id)
        expect(json_response["meta"]["total_count"]).to eq(1)
      end
    end

    context "with filtering" do
      let!(:btc_signal) do
        create(:signal_alert, symbol: "BTC-USD", strategy_name: "Strategy1", side: "long", signal_type: "entry",
          confidence: 80)
      end
      let!(:eth_signal) do
        create(:signal_alert, symbol: "ETH-USD", strategy_name: "Strategy2", side: "short", signal_type: "exit",
          confidence: 60)
      end

      it "filters by symbol" do
        get "/signals", headers: @headers, params: {symbol: "BTC-USD"}

        json_response = JSON.parse(response.body)
        expect(json_response["signals"].length).to eq(1)
        expect(json_response["signals"][0]["symbol"]).to eq("BTC-USD")
      end

      it "filters by strategy" do
        get "/signals", headers: @headers, params: {strategy: "Strategy1"}

        json_response = JSON.parse(response.body)
        expect(json_response["signals"].length).to eq(1)
        expect(json_response["signals"][0]["strategy_name"]).to eq("Strategy1")
      end

      it "filters by side" do
        get "/signals", headers: @headers, params: {side: "long"}

        json_response = JSON.parse(response.body)
        expect(json_response["signals"].length).to eq(1)
        expect(json_response["signals"][0]["side"]).to eq("long")
      end

      it "filters by signal_type" do
        get "/signals", headers: @headers, params: {signal_type: "entry"}

        json_response = JSON.parse(response.body)
        expect(json_response["signals"].length).to eq(1)
        expect(json_response["signals"][0]["signal_type"]).to eq("entry")
      end

      it "filters by minimum confidence" do
        get "/signals", headers: @headers, params: {min_confidence: 70}

        json_response = JSON.parse(response.body)
        expect(json_response["signals"].length).to eq(1)
        expect(json_response["signals"][0]["confidence"]).to eq(80.0)
      end

      it "filters by maximum confidence" do
        get "/signals", headers: @headers, params: {max_confidence: 70}

        json_response = JSON.parse(response.body)
        expect(json_response["signals"].length).to eq(1)
        expect(json_response["signals"][0]["confidence"]).to eq(60.0)
      end

      it "combines multiple filters" do
        get "/signals", headers: @headers, params: {symbol: "BTC-USD", side: "long", min_confidence: 70}

        json_response = JSON.parse(response.body)
        expect(json_response["signals"].length).to eq(1)
        expect(json_response["signals"][0]["symbol"]).to eq("BTC-USD")
        expect(json_response["signals"][0]["side"]).to eq("long")
      end

      it "returns empty results when no signals match filters" do
        get "/signals", headers: @headers, params: {symbol: "BTC-USD", side: "short"}

        json_response = JSON.parse(response.body)
        expect(json_response["signals"].length).to eq(0)
      end
    end

    context "with pagination" do
      before do
        create_list(:signal_alert, 75, alert_status: "active")
      end

      it "paginates results with default per_page" do
        get "/signals", headers: @headers

        json_response = JSON.parse(response.body)
        expect(json_response["signals"].length).to eq(50)
        expect(json_response["meta"]["per_page"]).to eq(50)
        expect(json_response["meta"]["total_pages"]).to eq(2)
      end

      it "respects custom per_page parameter" do
        get "/signals", headers: @headers, params: {per_page: 25}

        json_response = JSON.parse(response.body)
        expect(json_response["signals"].length).to eq(25)
        expect(json_response["meta"]["per_page"]).to eq(25)
        expect(json_response["meta"]["total_pages"]).to eq(3)
      end

      it "handles page parameter" do
        get "/signals", headers: @headers, params: {page: 2, per_page: 25}

        json_response = JSON.parse(response.body)
        expect(json_response["meta"]["current_page"]).to eq(2)
      end
    end
  end

  describe "GET /signals/:id" do
    before do
      @headers = {"X-API-Key" => api_key}
    end

    context "with existing signal" do
      it "returns the signal details" do
        get "/signals/#{signal_alert.id}", headers: @headers

        expect(response).to have_http_status(:success)
        json_response = JSON.parse(response.body)
        expect(json_response["id"]).to eq(signal_alert.id)
        expect(json_response["symbol"]).to eq(signal_alert.symbol)
        expect(json_response["confidence"]).to eq(signal_alert.confidence.to_f)
      end
    end

    context "with non-existent signal" do
      it "returns not found error" do
        get "/signals/99999", headers: @headers

        expect(response).to have_http_status(:not_found)
        json_response = JSON.parse(response.body)
        expect(json_response["error"]).to eq("Signal not found")
      end
    end
  end

  describe "POST /signals/evaluate" do
    before do
      @headers = {"X-API-Key" => api_key}
    end

    context "without symbol parameter" do
      it "evaluates all pairs successfully" do
        allow(real_time_evaluator).to receive(:evaluate_all_pairs)

        post "/signals/evaluate", headers: @headers

        expect(response).to have_http_status(:success)
        json_response = JSON.parse(response.body)
        expect(json_response["message"]).to eq("Evaluated signals for all enabled trading pairs")
        expect(real_time_evaluator).to have_received(:evaluate_all_pairs)
      end

      it "adds Sentry breadcrumbs for bulk evaluation" do
        post "/signals/evaluate", headers: @headers

        expect(SentryHelper).to have_received(:add_breadcrumb).with(
          message: "Signal evaluation requested",
          category: "trading",
          level: "info",
          data: hash_including(controller: "signal", action: "evaluate")
        )

        expect(SentryHelper).to have_received(:add_breadcrumb).with(
          message: "Bulk signal evaluation completed",
          category: "trading",
          level: "info",
          data: {evaluation_type: "all_pairs"}
        )
      end
    end

    context "with valid symbol parameter" do
      before do
        trading_pair # Create the trading pair
      end

      it "evaluates specific symbol successfully" do
        allow(real_time_evaluator).to receive(:evaluate_pair)

        post "/signals/evaluate", headers: @headers, params: {symbol: "BTC-USD"}

        expect(response).to have_http_status(:success)
        json_response = JSON.parse(response.body)
        expect(json_response["message"]).to eq("Evaluated signals for BTC-USD")
        expect(real_time_evaluator).to have_received(:evaluate_pair).with(trading_pair)
      end

      it "adds Sentry breadcrumbs for single pair evaluation" do
        post "/signals/evaluate", headers: @headers, params: {symbol: "BTC-USD"}

        expect(SentryHelper).to have_received(:add_breadcrumb).with(
          message: "Signal evaluation requested",
          category: "trading",
          level: "info",
          data: hash_including(controller: "signal", action: "evaluate", symbol: "BTC-USD")
        )

        expect(SentryHelper).to have_received(:add_breadcrumb).with(
          message: "Signal evaluation completed",
          category: "trading",
          level: "info",
          data: {symbol: "BTC-USD", evaluation_type: "single_pair"}
        )
      end
    end

    context "with invalid symbol parameter" do
      it "returns not found error for non-existent trading pair" do
        post "/signals/evaluate", headers: @headers, params: {symbol: "INVALID-USD"}

        expect(response).to have_http_status(:not_found)
        json_response = JSON.parse(response.body)
        expect(json_response["error"]).to eq("Trading pair not found: INVALID-USD")
      end

      it "tracks trading pair not found errors in Sentry" do
        post "/signals/evaluate", headers: @headers, params: {symbol: "INVALID-USD"}

        expect(Sentry).to have_received(:with_scope)
        expect(Sentry).to have_received(:capture_message).with("Trading pair not found for signal evaluation",
          level: "warning")
      end
    end

    context "when RealTimeSignalEvaluator raises an error" do
      before do
        trading_pair # Create the trading pair
        allow(real_time_evaluator).to receive(:evaluate_pair).and_raise(StandardError, "Evaluation failed")
      end

      it "captures the error in Sentry and re-raises" do
        expect do
          post "/signals/evaluate", headers: @headers, params: {symbol: "BTC-USD"}
        end.to raise_error(StandardError, "Evaluation failed")

        expect(Sentry).to have_received(:with_scope)
        expect(Sentry).to have_received(:capture_exception)
      end
    end
  end

  describe "GET /signals/active" do
    before do
      @headers = {"X-API-Key" => api_key}
    end

    context "with active signals" do
      let!(:active_signal1) { create(:signal_alert, alert_status: "active", confidence: 90) }
      let!(:active_signal2) { create(:signal_alert, alert_status: "active", confidence: 80) }
      let!(:triggered_signal) { create(:signal_alert, :triggered) }
      let!(:expired_signal) { create(:signal_alert, :expired) }

      it "returns only active signals ordered by confidence" do
        get "/signals/active", headers: @headers

        expect(response).to have_http_status(:success)
        json_response = JSON.parse(response.body)
        expect(json_response["signals"].length).to eq(2)
        expect(json_response["count"]).to eq(2)

        # Verify ordering by confidence (desc)
        expect(json_response["signals"][0]["confidence"]).to eq(90.0)
        expect(json_response["signals"][1]["confidence"]).to eq(80.0)
      end

      it "respects limit parameter" do
        get "/signals/active", headers: @headers, params: {limit: 1}

        json_response = JSON.parse(response.body)
        expect(json_response["signals"].length).to eq(1)
        expect(json_response["count"]).to eq(1)
      end

      it "uses default limit of 100" do
        create_list(:signal_alert, 150, alert_status: "active")
        get "/signals/active", headers: @headers

        json_response = JSON.parse(response.body)
        expect(json_response["signals"].length).to eq(100)
      end
    end

    context "with filtering" do
      let!(:btc_signal) { create(:signal_alert, symbol: "BTC-USD", alert_status: "active") }
      let!(:eth_signal) { create(:signal_alert, symbol: "ETH-USD", alert_status: "active") }

      it "applies filters to active signals" do
        get "/signals/active", headers: @headers, params: {symbol: "BTC-USD"}

        json_response = JSON.parse(response.body)
        expect(json_response["signals"].length).to eq(1)
        expect(json_response["signals"][0]["symbol"]).to eq("BTC-USD")
      end
    end
  end

  describe "GET /signals/high_confidence" do
    before do
      @headers = {"X-API-Key" => api_key}
    end

    context "with high confidence signals" do
      let!(:high_conf_signal) { create(:signal_alert, :high_confidence, alert_status: "active", confidence: 85) }
      let!(:low_conf_signal) { create(:signal_alert, :low_confidence, alert_status: "active", confidence: 60) }
      let!(:medium_conf_signal) { create(:signal_alert, alert_status: "active", confidence: 75) }

      it "returns signals above default threshold (70)" do
        get "/signals/high_confidence", headers: @headers

        expect(response).to have_http_status(:success)
        json_response = JSON.parse(response.body)
        expect(json_response["signals"].length).to eq(2)
        expect(json_response["threshold"]).to eq("70")
        expect(json_response["count"]).to eq(2)

        # Verify all returned signals are above threshold
        json_response["signals"].each do |signal|
          expect(signal["confidence"]).to be >= 70
        end
      end

      it "respects custom threshold parameter" do
        get "/signals/high_confidence", headers: @headers, params: {threshold: 80}

        json_response = JSON.parse(response.body)
        expect(json_response["signals"].length).to eq(1)
        expect(json_response["threshold"]).to eq("80")
        expect(json_response["signals"][0]["confidence"]).to eq(85.0)
      end

      it "respects limit parameter" do
        create_list(:signal_alert, 60, :high_confidence, alert_status: "active")
        get "/signals/high_confidence", headers: @headers, params: {limit: 25}

        json_response = JSON.parse(response.body)
        expect(json_response["signals"].length).to eq(25)
      end

      it "uses default limit of 50" do
        create_list(:signal_alert, 75, :high_confidence, alert_status: "active")
        get "/signals/high_confidence", headers: @headers

        json_response = JSON.parse(response.body)
        expect(json_response["signals"].length).to eq(50)
      end
    end

    context "with filtering" do
      let!(:btc_high_conf) { create(:signal_alert, symbol: "BTC-USD", confidence: 85, alert_status: "active") }
      let!(:eth_high_conf) { create(:signal_alert, symbol: "ETH-USD", confidence: 80, alert_status: "active") }

      it "applies filters to high confidence signals" do
        get "/signals/high_confidence", headers: @headers, params: {symbol: "BTC-USD"}

        json_response = JSON.parse(response.body)
        expect(json_response["signals"].length).to eq(1)
        expect(json_response["signals"][0]["symbol"]).to eq("BTC-USD")
      end
    end
  end

  describe "GET /signals/recent" do
    before do
      @headers = {"X-API-Key" => api_key}
    end

    context "with recent signals" do
      let!(:very_recent_signal) { create(:signal_alert, alert_timestamp: 30.minutes.ago) }
      let!(:recent_signal) { create(:signal_alert, alert_timestamp: 45.minutes.ago) }
      let!(:old_signal) { create(:signal_alert, alert_timestamp: 2.hours.ago) }

      it "returns signals from default 1 hour period" do
        get "/signals/recent", headers: @headers

        expect(response).to have_http_status(:success)
        json_response = JSON.parse(response.body)
        expect(json_response["signals"].length).to eq(2)
        expect(json_response["hours"]).to eq("1")
        expect(json_response["count"]).to eq(2)
      end

      it "respects custom hours parameter" do
        get "/signals/recent", headers: @headers, params: {hours: 3}

        json_response = JSON.parse(response.body)
        expect(json_response["signals"].length).to eq(3)
        expect(json_response["hours"]).to eq("3")
      end

      it "orders signals by alert_timestamp descending" do
        get "/signals/recent", headers: @headers

        json_response = JSON.parse(response.body)
        timestamps = json_response["signals"].map { |s| Time.parse(s["alert_timestamp"]) }
        expect(timestamps).to eq(timestamps.sort.reverse)
      end

      it "respects limit parameter" do
        create_list(:signal_alert, 150, alert_timestamp: 30.minutes.ago)
        get "/signals/recent", headers: @headers, params: {limit: 75}

        json_response = JSON.parse(response.body)
        expect(json_response["signals"].length).to eq(75)
      end

      it "uses default limit of 100" do
        create_list(:signal_alert, 150, alert_timestamp: 30.minutes.ago)
        get "/signals/recent", headers: @headers

        json_response = JSON.parse(response.body)
        expect(json_response["signals"].length).to eq(100)
      end
    end

    context "with filtering" do
      let!(:btc_recent) { create(:signal_alert, symbol: "BTC-USD", alert_timestamp: 30.minutes.ago) }
      let!(:eth_recent) { create(:signal_alert, symbol: "ETH-USD", alert_timestamp: 45.minutes.ago) }

      it "applies filters to recent signals" do
        get "/signals/recent", headers: @headers, params: {symbol: "BTC-USD"}

        json_response = JSON.parse(response.body)
        expect(json_response["signals"].length).to eq(1)
        expect(json_response["signals"][0]["symbol"]).to eq("BTC-USD")
      end
    end
  end

  describe "GET /signals/stats" do
    before do
      @headers = {"X-API-Key" => api_key}
    end

    context "with various signals" do
      let!(:active_signal) do
        create(:signal_alert, alert_status: "active", confidence: 85, symbol: "BTC-USD", strategy_name: "Strategy1")
      end
      let!(:triggered_signal) do
        create(:signal_alert, :triggered, confidence: 75, symbol: "ETH-USD", strategy_name: "Strategy2")
      end
      let!(:expired_signal) { create(:signal_alert, :expired, confidence: 65) }
      let!(:high_conf_signal) { create(:signal_alert, :high_confidence, confidence: 90) }
      let!(:old_signal) { create(:signal_alert, alert_timestamp: 25.hours.ago) }

      it "returns comprehensive statistics for default 24 hour period" do
        get "/signals/stats", headers: @headers

        expect(response).to have_http_status(:success)
        json_response = JSON.parse(response.body)

        expect(json_response["active_signals"]).to eq(2) # active_signal and high_conf_signal
        expect(json_response["recent_signals"]).to eq(4) # all except old_signal
        expect(json_response["triggered_signals"]).to eq(1)
        expect(json_response["expired_signals"]).to eq(1)
        expect(json_response["high_confidence_signals"]).to eq(2) # active_signal (85) and high_conf_signal (90)
        expect(json_response["time_range_hours"]).to eq("24")

        # Test grouped data
        expect(json_response["signals_by_symbol"]).to include("BTC-USD" => 1, "ETH-USD" => 1)
        expect(json_response["signals_by_strategy"]).to include("Strategy1" => 1, "Strategy2" => 1)

        # Test average confidence (should include recent signals)
        expected_avg = (85 + 75 + 65 + 90) / 4.0
        expect(json_response["average_confidence"]).to eq(expected_avg.round(2))
      end

      it "respects custom hours parameter" do
        get "/signals/stats", headers: @headers, params: {hours: 1}

        json_response = JSON.parse(response.body)
        expect(json_response["time_range_hours"]).to eq("1")
        expect(json_response["recent_signals"]).to eq(4) # all signals within 1 hour
      end

      it "handles edge case with no signals" do
        SignalAlert.destroy_all
        get "/signals/stats", headers: @headers

        json_response = JSON.parse(response.body)
        expect(json_response["active_signals"]).to eq(0)
        expect(json_response["recent_signals"]).to eq(0)
        expect(json_response["average_confidence"]).to be_nil
        expect(json_response["signals_by_symbol"]).to eq({})
        expect(json_response["signals_by_strategy"]).to eq({})
      end
    end
  end

  describe "POST /signals/:id/trigger" do
    before do
      @headers = {"X-API-Key" => api_key}
    end

    context "with existing signal" do
      it "marks signal as triggered successfully" do
        expect(signal_alert.alert_status).to eq("active")

        post "/signals/#{signal_alert.id}/trigger", headers: @headers

        expect(response).to have_http_status(:success)
        json_response = JSON.parse(response.body)
        expect(json_response["message"]).to eq("Signal marked as triggered")
        expect(json_response["signal"]["alert_status"]).to eq("triggered")

        signal_alert.reload
        expect(signal_alert.alert_status).to eq("triggered")
        expect(signal_alert.triggered_at).to be_present
      end
    end

    context "with non-existent signal" do
      it "returns not found error" do
        post "/signals/99999/trigger", headers: @headers

        expect(response).to have_http_status(:not_found)
        json_response = JSON.parse(response.body)
        expect(json_response["error"]).to eq("Signal not found")
      end
    end
  end

  describe "POST /signals/:id/cancel" do
    before do
      @headers = {"X-API-Key" => api_key}
    end

    context "with existing signal" do
      it "cancels signal successfully" do
        expect(signal_alert.alert_status).to eq("active")

        post "/signals/#{signal_alert.id}/cancel", headers: @headers

        expect(response).to have_http_status(:success)
        json_response = JSON.parse(response.body)
        expect(json_response["message"]).to eq("Signal cancelled")
        expect(json_response["signal"]["alert_status"]).to eq("cancelled")

        signal_alert.reload
        expect(signal_alert.alert_status).to eq("cancelled")
      end
    end

    context "with non-existent signal" do
      it "returns not found error" do
        post "/signals/99999/cancel", headers: @headers

        expect(response).to have_http_status(:not_found)
        json_response = JSON.parse(response.body)
        expect(json_response["error"]).to eq("Signal not found")
      end
    end
  end

  describe "GET /signals/health" do
    it "does not require authentication" do
      get "/signals/health"
      expect(response).to have_http_status(:success)
    end

    context "with signals in database" do
      let!(:latest_signal) { create(:signal_alert, alert_timestamp: 30.minutes.ago) }
      let!(:older_signal) { create(:signal_alert, alert_timestamp: 2.hours.ago) }
      let!(:active_signal) { create(:signal_alert, alert_status: "active") }
      let!(:recent_signal) { create(:signal_alert, alert_timestamp: 45.minutes.ago) }

      it "returns health status with signal metrics" do
        get "/signals/health"

        expect(response).to have_http_status(:success)
        json_response = JSON.parse(response.body)

        expect(json_response["status"]).to eq("healthy")
        expect(json_response["last_signal_timestamp"]).to be_present
        expect(json_response["recent_signals_count"]).to eq(2) # signals within 1 hour
        expect(json_response["active_signals_count"]).to eq(1)
        expect(json_response["timestamp"]).to be_present

        # Verify timestamp format
        expect { Time.parse(json_response["timestamp"]) }.not_to raise_error
      end

      it "returns last signal timestamp correctly" do
        get "/signals/health"

        json_response = JSON.parse(response.body)
        last_timestamp = Time.parse(json_response["last_signal_timestamp"])
        expect(last_timestamp).to be_within(1.second).of(latest_signal.alert_timestamp)
      end
    end

    context "with no signals" do
      it "handles empty database gracefully" do
        get "/signals/health"

        expect(response).to have_http_status(:success)
        json_response = JSON.parse(response.body)

        expect(json_response["status"]).to eq("healthy")
        expect(json_response["last_signal_timestamp"]).to be_nil
        expect(json_response["recent_signals_count"]).to eq(0)
        expect(json_response["active_signals_count"]).to eq(0)
      end
    end
  end

  describe "error handling" do
    before do
      @headers = {"X-API-Key" => api_key}
    end

    context "when ApplicationController error handling is triggered" do
      before do
        # Mock a method to raise an error
        allow(SignalAlert).to receive(:active).and_raise(StandardError, "Database connection failed")
      end

      it "captures errors in Sentry and returns appropriate response" do
        get "/signals", headers: @headers

        expect(response).to have_http_status(:internal_server_error)
        json_response = JSON.parse(response.body)
        expect(json_response["error"]).to eq("Internal server error")

        # In development, error message should be included
        expect(json_response["message"]).to eq("Database connection failed") if Rails.env.development?
      end
    end
  end

  describe "API response format" do
    before do
      @headers = {"X-API-Key" => api_key}
    end

    it "returns properly formatted signal data" do
      signal = create(:signal_alert,
        symbol: "BTC-USD",
        side: "long",
        signal_type: "entry",
        strategy_name: "TestStrategy",
        confidence: 85.5,
        entry_price: 50_000.0,
        stop_loss: 49_000.0,
        take_profit: 52_000.0,
        quantity: 10,
        timeframe: "15m",
        alert_status: "active",
        metadata: {"test" => "data"},
        strategy_data: {"ema" => 49_900})

      get "/signals/#{signal.id}", headers: @headers

      expect(response).to have_http_status(:success)
      json_response = JSON.parse(response.body)

      expect(json_response).to include(
        "id" => signal.id,
        "symbol" => "BTC-USD",
        "side" => "long",
        "signal_type" => "entry",
        "strategy_name" => "TestStrategy",
        "confidence" => 85.5,
        "entry_price" => 50_000.0,
        "stop_loss" => 49_000.0,
        "take_profit" => 52_000.0,
        "quantity" => 10,
        "timeframe" => "15m",
        "alert_status" => "active",
        "metadata" => {"test" => "data"}
      )

      # Verify timestamp formats
      expect { Time.parse(json_response["alert_timestamp"]) }.not_to raise_error
      expect { Time.parse(json_response["created_at"]) }.not_to raise_error
      expect { Time.parse(json_response["updated_at"]) }.not_to raise_error
      expect { Time.parse(json_response["expires_at"]) if json_response["expires_at"] }.not_to raise_error
    end
  end

  describe "edge cases and performance" do
    before do
      @headers = {"X-API-Key" => api_key}
    end

    context "with large datasets" do
      before do
        create_list(:signal_alert, 500, alert_status: "active")
      end

      it "handles large result sets efficiently" do
        start_time = Time.current
        get "/signals", headers: @headers
        duration = Time.current - start_time

        expect(response).to have_http_status(:success)
        expect(duration).to be < 5.seconds # Performance expectation

        json_response = JSON.parse(response.body)
        expect(json_response["signals"].length).to eq(50) # Default pagination
      end
    end

    context "with invalid parameters" do
      it "handles non-numeric confidence values gracefully" do
        get "/signals", headers: @headers, params: {min_confidence: "invalid"}
        expect(response).to have_http_status(:success)
        # Should not filter by confidence if invalid
      end

      it "handles non-numeric limit values gracefully" do
        create_list(:signal_alert, 10, alert_status: "active")
        get "/signals/active", headers: @headers, params: {limit: "invalid"}

        expect(response).to have_http_status(:success)
        json_response = JSON.parse(response.body)
        expect(json_response["signals"].length).to eq(10) # Should use default behavior
      end

      it "handles non-numeric hours parameter gracefully" do
        create(:signal_alert, alert_timestamp: 30.minutes.ago)
        get "/signals/recent", headers: @headers, params: {hours: "invalid"}

        expect(response).to have_http_status(:success)
        json_response = JSON.parse(response.body)
        expect(json_response["hours"]).to eq("invalid") # Should echo back the parameter
      end
    end
  end

  describe "concurrent access" do
    before do
      @headers = {"X-API-Key" => api_key}
    end

    it "handles concurrent signal updates during read operations" do
      signal = create(:signal_alert, alert_status: "active")

      # Simulate concurrent access
      threads = []
      results = []

      5.times do
        threads << Thread.new do
          get "/signals/#{signal.id}", headers: @headers
          results << response.status
        end
      end

      threads.each(&:join)

      # All requests should succeed
      expect(results).to all(eq(200))
    end
  end

  describe "data integrity" do
    before do
      @headers = {"X-API-Key" => api_key}
    end

    it "maintains data consistency across endpoints" do
      signal = create(:signal_alert, alert_status: "active", confidence: 85)

      # Check signal appears in index
      get "/signals", headers: @headers
      index_signals = JSON.parse(response.body)["signals"]
      expect(index_signals.map { |s| s["id"] }).to include(signal.id)

      # Check signal appears in active endpoint
      get "/signals/active", headers: @headers
      active_signals = JSON.parse(response.body)["signals"]
      expect(active_signals.map { |s| s["id"] }).to include(signal.id)

      # Check signal appears in high_confidence endpoint
      get "/signals/high_confidence", headers: @headers
      high_conf_signals = JSON.parse(response.body)["signals"]
      expect(high_conf_signals.map { |s| s["id"] }).to include(signal.id)

      # Check signal details are consistent
      get "/signals/#{signal.id}", headers: @headers
      signal_details = JSON.parse(response.body)

      index_signal = index_signals.find { |s| s["id"] == signal.id }
      expect(signal_details).to eq(index_signal)
    end
  end
end
