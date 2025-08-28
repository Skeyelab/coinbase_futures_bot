# frozen_string_literal: true

require "rails_helper"

RSpec.describe SlackNotificationService, type: :service do
  let(:mock_client) { instance_double(Slack::Web::Client) }

  before do
    # Mock the client method directly instead of the constructor
    allow(SlackNotificationService).to receive(:client).and_return(mock_client)
    allow(mock_client).to receive(:chat_postMessage)
    stub_const("ENV", ENV.to_hash.merge({
      "SLACK_ENABLED" => "true",
      "SLACK_BOT_TOKEN" => "xoxb-test-token",
      "SLACK_SIGNALS_CHANNEL" => "#test-signals",
      "SLACK_POSITIONS_CHANNEL" => "#test-positions",
      "SLACK_STATUS_CHANNEL" => "#test-status",
      "SLACK_ALERTS_CHANNEL" => "#test-alerts"
    }))
  end

  describe ".signal_generated" do
    let(:signal_data) do
      {
        symbol: "BTC-USD",
        side: "long",
        price: 50_000.0,
        quantity: 0.1,
        tp: 52_000.0,
        sl: 48_000.0,
        confidence: 75
      }
    end

    it "sends signal notification to correct channel" do
      expect(mock_client).to receive(:chat_postMessage) do |args|
        expect(args[:channel]).to eq("#test-signals")
        expect(args[:text]).to include("New Trading Signal: BTC-USD")
        expect(args[:attachments]).to be_present
      end

      described_class.signal_generated(signal_data)
    end

    it "includes all signal data in message" do
      expect(mock_client).to receive(:chat_postMessage) do |args|
        attachment = args[:attachments].first
        fields = attachment[:fields]

        expect(fields.find { |f| f[:title] == "Symbol" }[:value]).to eq("BTC-USD")
        expect(fields.find { |f| f[:title] == "Side" }[:value]).to eq("LONG")
        expect(fields.find { |f| f[:title] == "Price" }[:value]).to eq("$50000.0")
        expect(fields.find { |f| f[:title] == "Confidence" }[:value]).to eq("75%")
      end

      described_class.signal_generated(signal_data)
    end

    it "does not send when disabled" do
      stub_const("ENV", ENV.to_hash.merge("SLACK_ENABLED" => "false"))

      expect(mock_client).not_to receive(:chat_postMessage)
      described_class.signal_generated(signal_data)
    end
  end

  describe ".position_update" do
    let(:position) do
      create(:position, product_id: "ETH-USD", side: "LONG", size: 1.0, entry_price: 3000.0, pnl: 150.0)
    end

    it "sends position opened notification" do
      expect(mock_client).to receive(:chat_postMessage) do |args|
        expect(args[:channel]).to eq("#test-positions")
        expect(args[:text]).to include("Position Opened: ETH-USD")
        expect(args[:attachments].first[:color]).to eq("good")
      end

      described_class.position_update(position, "opened")
    end

    it "sends position closed notification with PnL color" do
      position.pnl = -100.0

      expect(mock_client).to receive(:chat_postMessage) do |args|
        expect(args[:text]).to include("Position Closed: ETH-USD")
        expect(args[:attachments].first[:color]).to eq("danger")
      end

      described_class.position_update(position, "closed")
    end
  end

  describe ".bot_status" do
    let(:status_data) do
      {
        status: "active",
        trading_active: true,
        open_positions: 5,
        daily_pnl: 250.0,
        last_signal_time: "10:30 UTC",
        healthy: true
      }
    end

    it "sends status update to correct channel" do
      expect(mock_client).to receive(:chat_postMessage) do |args|
        expect(args[:channel]).to eq("#test-status")
        expect(args[:text]).to include("Bot Status Update")
        expect(args[:attachments].first[:color]).to eq("good")
      end

      described_class.bot_status(status_data)
    end
  end

  describe ".alert" do
    it "sends critical alert to alerts channel" do
      expect(mock_client).to receive(:chat_postMessage) do |args|
        expect(args[:channel]).to eq("#test-alerts")
        expect(args[:text]).to include("🚨 Alert: System Error")
        expect(args[:attachments].first[:color]).to eq("danger")
      end

      described_class.alert("critical", "System Error", "Database connection lost")
    end

    it "sends warning alert with correct emoji and color" do
      expect(mock_client).to receive(:chat_postMessage) do |args|
        expect(args[:text]).to include("⚠️ Alert: High Memory Usage")
        expect(args[:attachments].first[:color]).to eq("warning")
      end

      described_class.alert("warning", "High Memory Usage")
    end
  end

  describe ".pnl_update" do
    let(:pnl_data) do
      {
        total_pnl: 500.0,
        daily_pnl: 100.0,
        open_positions: 3,
        closed_today: 2,
        win_rate: 66.7
      }
    end

    it "sends PnL update with positive trend" do
      expect(mock_client).to receive(:chat_postMessage) do |args|
        expect(args[:text]).to include("📈 PnL Update")
        expect(args[:attachments].first[:color]).to eq("good")
      end

      described_class.pnl_update(pnl_data)
    end
  end

  describe "error handling" do
    it "handles Slack API errors gracefully" do
      allow(mock_client).to receive(:chat_postMessage).and_raise(Slack::Web::Api::Errors::SlackError.new("rate_limited"))
      expect(Rails.logger).to receive(:error).with("[Slack] API Error: rate_limited").at_least(:once)
      expect(Rails.logger).to receive(:error).with("[Slack] Failed to send message after 3 retries")

      described_class.alert("info", "Test Alert")
    end

    it "retries on API errors with exponential backoff" do
      call_count = 0
      allow(mock_client).to receive(:chat_postMessage) do
        call_count += 1
        raise Slack::Web::Api::Errors::SlackError.new("rate_limited") if call_count <= 2

        true
      end

      expect(described_class).to receive(:sleep).with(2).once
      expect(described_class).to receive(:sleep).with(4).once

      described_class.alert("info", "Test Alert")
    end

    it "gives up after max retries" do
      allow(mock_client).to receive(:chat_postMessage).and_raise(Slack::Web::Api::Errors::SlackError.new("rate_limited"))
      expect(Rails.logger).to receive(:error).with("[Slack] API Error: rate_limited").at_least(:once)
      expect(Rails.logger).to receive(:error).with("[Slack] Failed to send message after 3 retries")

      described_class.alert("info", "Test Alert")
    end
  end

  describe "private methods" do
    describe "#duration_in_words" do
      it "formats duration correctly" do
        start_time = Time.current
        end_time = start_time + 2.hours + 30.minutes

        result = described_class.send(:duration_in_words, start_time, end_time)
        expect(result).to eq("2h 30m")
      end

      it "handles minutes only" do
        start_time = Time.current
        end_time = start_time + 45.minutes

        result = described_class.send(:duration_in_words, start_time, end_time)
        expect(result).to eq("45m")
      end

      it "returns N/A for nil times" do
        result = described_class.send(:duration_in_words, nil, nil)
        expect(result).to eq("N/A")
      end
    end
  end
end
