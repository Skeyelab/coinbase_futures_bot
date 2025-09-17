# frozen_string_literal: true

require "rails_helper"

RSpec.describe SlackNotificationService, type: :service do
  let(:mock_response) { instance_double(Faraday::Response) }

  before do
    # Mock logging and error tracking
    allow(Rails.logger).to receive(:info)
    allow(Rails.logger).to receive(:error)
    allow(Rails.logger).to receive(:debug)
    allow(Sentry).to receive(:with_scope)
    allow(Sentry).to receive(:capture_exception)
    allow(Sentry).to receive(:capture_message)

    # Mock all ENV variables that might be accessed
    allow(ENV).to receive(:[]).and_call_original

    # Mock sleep calls globally to avoid actual delays in tests
    allow(described_class).to receive(:sleep).and_return(true)
  end

  after do
    # Clean up any global mocks to prevent test leakage
    allow(Slack::Web::Client).to receive(:new).and_call_original
  end

  # Mock client will be created fresh in each test context

  describe "#enabled?" do
    context "when SLACK_ENABLED is true" do
      before { allow(ENV).to receive(:[]).with("SLACK_ENABLED").and_return("true") }

      context "when SLACK_BOT_TOKEN is present" do
        before { allow(ENV).to receive(:[]).with("SLACK_BOT_TOKEN").and_return("xoxb-token") }

        it "returns true" do
          expect(described_class.send(:enabled?)).to be true
        end
      end

      context "when SLACK_BOT_TOKEN is not present" do
        before { allow(ENV).to receive(:[]).with("SLACK_BOT_TOKEN").and_return(nil) }

        it "returns false" do
          expect(described_class.send(:enabled?)).to be false
        end
      end
    end

    context "when SLACK_ENABLED is not true" do
      before { allow(ENV).to receive(:[]).with("SLACK_ENABLED").and_return("false") }

      it "returns false" do
        expect(described_class.send(:enabled?)).to be false
      end
    end
  end

  describe "#bot_token" do
    it "returns the SLACK_BOT_TOKEN environment variable" do
      allow(ENV).to receive(:[]).with("SLACK_BOT_TOKEN").and_return("test-token")
      expect(described_class.send(:bot_token)).to eq("test-token")
    end
  end

  describe "channel methods" do
    describe "#signals_channel" do
      context "when SLACK_SIGNALS_CHANNEL is set" do
        before { allow(ENV).to receive(:[]).with("SLACK_SIGNALS_CHANNEL").and_return("#custom-signals") }

        it "returns the custom channel" do
          expect(described_class.send(:signals_channel)).to eq("#custom-signals")
        end
      end

      context "when SLACK_SIGNALS_CHANNEL is not set" do
        before { allow(ENV).to receive(:[]).with("SLACK_SIGNALS_CHANNEL").and_return(nil) }

        it "returns the default channel" do
          expect(described_class.send(:signals_channel)).to eq("#trading-signals")
        end
      end
    end

    describe "#positions_channel" do
      context "when SLACK_POSITIONS_CHANNEL is set" do
        before { allow(ENV).to receive(:[]).with("SLACK_POSITIONS_CHANNEL").and_return("#custom-positions") }

        it "returns the custom channel" do
          expect(described_class.send(:positions_channel)).to eq("#custom-positions")
        end
      end

      context "when SLACK_POSITIONS_CHANNEL is not set" do
        before { allow(ENV).to receive(:[]).with("SLACK_POSITIONS_CHANNEL").and_return(nil) }

        it "returns the default channel" do
          expect(described_class.send(:positions_channel)).to eq("#trading-positions")
        end
      end
    end

    describe "#status_channel" do
      context "when SLACK_STATUS_CHANNEL is set" do
        before { allow(ENV).to receive(:[]).with("SLACK_STATUS_CHANNEL").and_return("#custom-status") }

        it "returns the custom channel" do
          expect(described_class.send(:status_channel)).to eq("#custom-status")
        end
      end

      context "when SLACK_STATUS_CHANNEL is not set" do
        before { allow(ENV).to receive(:[]).with("SLACK_STATUS_CHANNEL").and_return(nil) }

        it "returns the default channel" do
          expect(described_class.send(:status_channel)).to eq("#bot-status")
        end
      end
    end

    describe "#alerts_channel" do
      context "when SLACK_ALERTS_CHANNEL is set" do
        before { allow(ENV).to receive(:[]).with("SLACK_ALERTS_CHANNEL").and_return("#custom-alerts") }

        it "returns the custom channel" do
          expect(described_class.send(:alerts_channel)).to eq("#custom-alerts")
        end
      end

      context "when SLACK_ALERTS_CHANNEL is not set" do
        before { allow(ENV).to receive(:[]).with("SLACK_ALERTS_CHANNEL").and_return(nil) }

        it "returns the default channel" do
          expect(described_class.send(:alerts_channel)).to eq("#trading-alerts")
        end
      end
    end
  end

  describe "#signal_generated" do
    let(:signal_data) do
      {
        symbol: "BTC-USD",
        side: "long",
        price: 50_000.0,
        quantity: 1,
        tp: 52_000.0,
        sl: 49_000.0,
        confidence: 80
      }
    end

    context "when service is enabled" do
      let(:mock_client) { instance_double(Slack::Web::Client) }

      before do
        allow(ENV).to receive(:[]).with("SLACK_ENABLED").and_return("true")
        allow(ENV).to receive(:[]).with("SLACK_BOT_TOKEN").and_return("xoxb-token")
        allow(Slack::Web::Client).to receive(:new).and_return(mock_client)
        allow(mock_client).to receive(:chat_postMessage).and_return(true)
        allow(described_class).to receive(:client).and_return(mock_client)
      end

      it "formats and sends the signal message" do
        expect(described_class).to receive(:format_signal_message).with(signal_data)
        expect(described_class).to receive(:send_message)
        described_class.signal_generated(signal_data)
      end

      it "uses the signals channel" do
        expect(described_class).to receive(:signals_channel)
        expect(described_class).to receive(:send_message)
        described_class.signal_generated(signal_data)
      end
    end

    context "when service is not enabled" do
      before do
        allow(ENV).to receive(:[]).with("SLACK_ENABLED").and_return("false")
      end

      it "returns early without sending" do
        expect(described_class).not_to receive(:format_signal_message)
        described_class.signal_generated(signal_data)
      end
    end

    context "when signal_data is invalid" do
      it "returns early for nil data" do
        expect(described_class).not_to receive(:format_signal_message)
        described_class.signal_generated(nil)
      end

      it "returns early for empty data" do
        expect(described_class).not_to receive(:format_signal_message)
        described_class.signal_generated({})
      end

      it "returns early for non-hash data" do
        expect(described_class).not_to receive(:format_signal_message)
        described_class.signal_generated("invalid")
      end
    end
  end

  describe "#position_update" do
    let(:mock_position) do
      double("Position",
        product_id: "BTC-USD",
        side: "long",
        size: 1,
        entry_price: 50_000.0,
        pnl: 100.0,
        close_time: Time.current,
        entry_time: 1.hour.ago)
    end
    let(:action) { "closed" }

    context "when service is enabled" do
      let(:mock_client) { instance_double(Slack::Web::Client) }

      before do
        allow(ENV).to receive(:[]).with("SLACK_ENABLED").and_return("true")
        allow(ENV).to receive(:[]).with("SLACK_BOT_TOKEN").and_return("xoxb-token")
        allow(Slack::Web::Client).to receive(:new).and_return(mock_client)
        allow(mock_client).to receive(:chat_postMessage).and_return(true)
        allow(described_class).to receive(:client).and_return(mock_client)
      end

      it "formats and sends the position message" do
        expect(described_class).to receive(:format_position_message).with(mock_position, action)
        expect(described_class).to receive(:send_message)
        described_class.position_update(mock_position, action)
      end

      it "uses the positions channel" do
        expect(described_class).to receive(:positions_channel)
        expect(described_class).to receive(:send_message)
        described_class.position_update(mock_position, action)
      end
    end

    context "when service is not enabled" do
      before do
        allow(ENV).to receive(:[]).with("SLACK_ENABLED").and_return("false")
      end

      it "returns early without sending" do
        expect(described_class).not_to receive(:format_position_message)
        described_class.position_update(mock_position, action)
      end
    end

    context "when position is invalid" do
      it "returns early for nil position" do
        expect(described_class).not_to receive(:format_position_message)
        described_class.position_update(nil, action)
      end
    end

    context "when action is invalid" do
      it "returns early for nil action" do
        expect(described_class).not_to receive(:format_position_message)
        described_class.position_update(mock_position, nil)
      end

      it "returns early for empty action" do
        expect(described_class).not_to receive(:format_position_message)
        described_class.position_update(mock_position, "")
      end
    end
  end

  describe "#bot_status" do
    let(:status_data) do
      {
        status: "active",
        trading_active: true,
        healthy: true,
        open_positions: 2,
        daily_pnl: 150.0
      }
    end

    context "when service is enabled" do
      let(:mock_client) { instance_double(Slack::Web::Client) }

      before do
        allow(ENV).to receive(:[]).with("SLACK_ENABLED").and_return("true")
        allow(ENV).to receive(:[]).with("SLACK_BOT_TOKEN").and_return("xoxb-token")
        allow(Slack::Web::Client).to receive(:new).and_return(mock_client)
        allow(mock_client).to receive(:chat_postMessage).and_return(true)
        allow(described_class).to receive(:client).and_return(mock_client)
      end

      it "formats and sends the status message" do
        expect(described_class).to receive(:format_status_message).with(status_data)
        expect(described_class).to receive(:send_message)
        described_class.bot_status(status_data)
      end

      it "uses the status channel" do
        expect(described_class).to receive(:status_channel)
        expect(described_class).to receive(:send_message)
        described_class.bot_status(status_data)
      end
    end

    context "when service is not enabled" do
      before do
        allow(ENV).to receive(:[]).with("SLACK_ENABLED").and_return("false")
      end

      it "returns early without sending" do
        expect(described_class).not_to receive(:format_status_message)
        described_class.bot_status(status_data)
      end
    end

    context "when status_data is invalid" do
      it "returns early for nil data" do
        expect(described_class).not_to receive(:format_status_message)
        described_class.bot_status(nil)
      end

      it "returns early for empty data" do
        expect(described_class).not_to receive(:format_status_message)
        described_class.bot_status({})
      end

      it "returns early for non-hash data" do
        expect(described_class).not_to receive(:format_status_message)
        described_class.bot_status("invalid")
      end
    end
  end

  describe "#alert" do
    let(:level) { "error" }
    let(:title) { "Test Alert" }
    let(:details) { "Something went wrong" }

    context "when service is enabled" do
      let(:mock_client) { instance_double(Slack::Web::Client) }

      before do
        allow(ENV).to receive(:[]).with("SLACK_ENABLED").and_return("true")
        allow(ENV).to receive(:[]).with("SLACK_BOT_TOKEN").and_return("xoxb-token")
        allow(Slack::Web::Client).to receive(:new).and_return(mock_client)
        allow(mock_client).to receive(:chat_postMessage).and_return(true)
        allow(described_class).to receive(:client).and_return(mock_client)
      end

      it "formats and sends the alert message" do
        expect(described_class).to receive(:format_alert_message).with(level, title, details)
        expect(described_class).to receive(:send_message)
        described_class.alert(level, title, details)
      end

      context "with critical level" do
        it "uses alerts channel" do
          expect(described_class).to receive(:alerts_channel)
          expect(described_class).to receive(:send_message)
          described_class.alert("critical", title)
        end
      end

      context "with error level" do
        it "uses alerts channel" do
          expect(described_class).to receive(:alerts_channel)
          expect(described_class).to receive(:send_message)
          described_class.alert("error", title)
        end
      end

      context "with other levels" do
        it "uses status channel" do
          expect(described_class).to receive(:status_channel)
          expect(described_class).to receive(:send_message)
          described_class.alert("info", title)
        end
      end
    end

    context "when service is not enabled" do
      before do
        allow(ENV).to receive(:[]).with("SLACK_ENABLED").and_return("false")
      end

      it "returns early without sending" do
        expect(described_class).not_to receive(:format_alert_message)
        described_class.alert(level, title)
      end
    end

    context "when parameters are invalid" do
      it "returns early for nil level" do
        expect(described_class).not_to receive(:format_alert_message)
        described_class.alert(nil, title)
      end

      it "returns early for empty level" do
        expect(described_class).not_to receive(:format_alert_message)
        described_class.alert("", title)
      end

      it "returns early for nil title" do
        expect(described_class).not_to receive(:format_alert_message)
        described_class.alert(level, nil)
      end

      it "returns early for empty title" do
        expect(described_class).not_to receive(:format_alert_message)
        described_class.alert(level, "")
      end
    end
  end

  describe "#pnl_update" do
    let(:pnl_data) do
      {
        total_pnl: 250.0,
        daily_pnl: 150.0,
        open_positions: 2
      }
    end

    context "when service is enabled" do
      let(:mock_client) { instance_double(Slack::Web::Client) }

      before do
        allow(ENV).to receive(:[]).with("SLACK_ENABLED").and_return("true")
        allow(ENV).to receive(:[]).with("SLACK_BOT_TOKEN").and_return("xoxb-token")
        allow(Slack::Web::Client).to receive(:new).and_return(mock_client)
        allow(mock_client).to receive(:chat_postMessage).and_return(true)
        allow(described_class).to receive(:client).and_return(mock_client)
      end

      it "formats and sends the PnL message" do
        expect(described_class).to receive(:format_pnl_message).with(pnl_data)
        expect(described_class).to receive(:send_message)
        described_class.pnl_update(pnl_data)
      end

      it "uses the positions channel" do
        expect(described_class).to receive(:positions_channel)
        expect(described_class).to receive(:send_message)
        described_class.pnl_update(pnl_data)
      end
    end

    context "when service is not enabled" do
      before do
        allow(ENV).to receive(:[]).with("SLACK_ENABLED").and_return("false")
      end

      it "returns early without sending" do
        expect(described_class).not_to receive(:format_pnl_message)
        described_class.pnl_update(pnl_data)
      end
    end

    context "when pnl_data is invalid" do
      it "returns early for nil data" do
        expect(described_class).not_to receive(:format_pnl_message)
        described_class.pnl_update(nil)
      end

      it "returns early for empty data" do
        expect(described_class).not_to receive(:format_pnl_message)
        described_class.pnl_update({})
      end

      it "returns early for non-hash data" do
        expect(described_class).not_to receive(:format_pnl_message)
        described_class.pnl_update("invalid")
      end
    end
  end

  describe "#health_check" do
    let(:health_data) do
      {
        overall_health: "healthy",
        database: true,
        coinbase_api: true,
        background_jobs: true
      }
    end

    context "when service is enabled" do
      let(:mock_client) { instance_double(Slack::Web::Client) }

      before do
        allow(ENV).to receive(:[]).with("SLACK_ENABLED").and_return("true")
        allow(ENV).to receive(:[]).with("SLACK_BOT_TOKEN").and_return("xoxb-token")
        allow(Slack::Web::Client).to receive(:new).and_return(mock_client)
        allow(mock_client).to receive(:chat_postMessage).and_return(true)
        allow(described_class).to receive(:client).and_return(mock_client)
      end

      it "formats and sends the health message" do
        expect(described_class).to receive(:format_health_message).with(health_data)
        expect(described_class).to receive(:send_message)
        described_class.health_check(health_data)
      end

      it "uses the status channel" do
        expect(described_class).to receive(:status_channel)
        expect(described_class).to receive(:send_message)
        described_class.health_check(health_data)
      end
    end

    context "when service is not enabled" do
      before do
        allow(ENV).to receive(:[]).with("SLACK_ENABLED").and_return("false")
      end

      it "returns early without sending" do
        expect(described_class).not_to receive(:format_health_message)
        described_class.health_check(health_data)
      end
    end
  end

  describe "#market_alert" do
    let(:market_data) do
      {
        alert_type: "volatility_spike",
        symbol: "BTC-USD",
        current_price: 50_000.0,
        volatility: 15.5
      }
    end

    context "when service is enabled" do
      let(:mock_client) { instance_double(Slack::Web::Client) }

      before do
        allow(ENV).to receive(:[]).with("SLACK_ENABLED").and_return("true")
        allow(ENV).to receive(:[]).with("SLACK_BOT_TOKEN").and_return("xoxb-token")
        allow(Slack::Web::Client).to receive(:new).and_return(mock_client)
        allow(mock_client).to receive(:chat_postMessage).and_return(true)
        allow(described_class).to receive(:client).and_return(mock_client)
      end

      it "formats and sends the market alert message" do
        expect(described_class).to receive(:format_market_message).with(market_data)
        expect(described_class).to receive(:send_message)
        described_class.market_alert(market_data)
      end

      it "uses the alerts channel" do
        expect(described_class).to receive(:alerts_channel)
        expect(described_class).to receive(:send_message)
        described_class.market_alert(market_data)
      end
    end

    context "when service is not enabled" do
      before do
        allow(ENV).to receive(:[]).with("SLACK_ENABLED").and_return("false")
      end

      it "returns early without sending" do
        expect(described_class).not_to receive(:format_market_message)
        described_class.market_alert(market_data)
      end
    end
  end

  describe "#send_message" do
    let(:message) { {text: "Test message", attachments: []} }
    let(:channel) { "#test-channel" }

    before do
      allow(ENV).to receive(:[]).with("SLACK_ENABLED").and_return("true")
      allow(ENV).to receive(:[]).with("SLACK_BOT_TOKEN").and_return("xoxb-token")
    end

    context "when message is valid" do
      it "uses the client for sending messages" do
        client = instance_double(Slack::Web::Client)
        allow(Slack::Web::Client).to receive(:new).and_return(client)
        allow(client).to receive(:chat_postMessage).and_return(true)
        allow(described_class).to receive(:client).and_return(client)

        described_class.send(:send_message, message, channel: channel)
        expect(described_class).to have_received(:client)
      end

      it "sends the message with correct parameters" do
        client = instance_double(Slack::Web::Client)
        allow(Slack::Web::Client).to receive(:new).and_return(client)
        allow(client).to receive(:chat_postMessage).and_return(true)
        allow(described_class).to receive(:client).and_return(client)

        expect(client).to receive(:chat_postMessage).with(
          channel: channel,
          text: message[:text],
          attachments: message[:attachments]
        )
        described_class.send(:send_message, message, channel: channel)
      end

      it "returns true on success" do
        client = instance_double(Slack::Web::Client)
        allow(Slack::Web::Client).to receive(:new).and_return(client)
        allow(client).to receive(:chat_postMessage).and_return(true)
        allow(described_class).to receive(:client).and_return(client)
        result = described_class.send(:send_message, message, channel: channel)
        expect(result).to be true
      end

      it "logs successful message sending" do
        client = instance_double(Slack::Web::Client)
        allow(Slack::Web::Client).to receive(:new).and_return(client)
        allow(client).to receive(:chat_postMessage).and_return(true)
        allow(described_class).to receive(:client).and_return(client)

        expect(Rails.logger).to receive(:info).with("[Slack] Message sent to #{channel}")
        described_class.send(:send_message, message, channel: channel)
      end
    end

    context "when message is invalid" do
      it "returns without sending for nil message" do
        result = described_class.send(:send_message, nil, channel: channel)
        expect(result).to be_nil
      end

      it "returns without sending for empty message" do
        result = described_class.send(:send_message, {}, channel: channel)
        expect(result).to be_nil
      end
    end

    context "when Slack API error occurs" do
      let(:slack_error) { Slack::Web::Api::Errors::SlackError.new("API Error") }
      let(:mock_client) { instance_double(Slack::Web::Client) }

      before do
        allow(Slack::Web::Client).to receive(:new).and_return(mock_client)
        allow(mock_client).to receive(:chat_postMessage).and_raise(slack_error)
        allow(described_class).to receive(:client).and_return(mock_client)
      end
      it "logs the error" do
        allow_any_instance_of(Slack::Web::Client).to receive(:chat_postMessage).and_raise(slack_error)
        # Mock sleep to avoid actual delays in tests
        allow(described_class).to receive(:sleep).and_return(true)

        expect(Rails.logger).to receive(:error).with("[Slack] API Error: API Error")
        described_class.send(:send_message, message, channel: channel)
      end

      it "sends error to Sentry" do
        allow_any_instance_of(Slack::Web::Client).to receive(:chat_postMessage).and_raise(slack_error)
        # Mock sleep to avoid actual delays in tests
        allow(described_class).to receive(:sleep).and_return(true)

        expect(Sentry).to receive(:with_scope)
        described_class.send(:send_message, message, channel: channel)
      end

      context "when retries are available" do
        it "retries with exponential backoff" do
          # Mock sleep to avoid actual delays in tests
          expect(described_class).to receive(:sleep).with(2).and_return(true)
          expect(described_class).to receive(:sleep).with(4).and_return(true)
          expect(described_class).to receive(:sleep).with(8).and_return(true)

          # Allow the recursive call to eventually succeed
          call_count = 0
          allow_any_instance_of(Slack::Web::Client).to receive(:chat_postMessage) do
            call_count += 1
            raise slack_error if call_count <= 3

            true
          end
          allow(described_class).to receive(:client).and_return(mock_client)

          described_class.send(:send_message, message, channel: channel)
        end

        it "retries up to max_retries times" do
          allow(described_class).to receive(:client).and_return(mock_client)
          # Mock sleep to avoid actual delays in tests
          allow(described_class).to receive(:sleep).and_return(true)
          expect(described_class).to receive(:send_message).exactly(4).times.and_call_original
          described_class.send(:send_message, message, channel: channel)
        end
      end

      context "when max retries exceeded" do
        let(:mock_client) { instance_double(Slack::Web::Client) }

        before do
          allow(Slack::Web::Client).to receive(:new).and_return(mock_client)
          allow(mock_client).to receive(:chat_postMessage).and_raise(slack_error)
        end

        it "logs max retries exceeded" do
          allow_any_instance_of(Slack::Web::Client).to receive(:chat_postMessage).and_raise(slack_error)
          # Mock sleep to avoid actual delays in tests
          allow(described_class).to receive(:sleep).and_return(true)

          expect(Rails.logger).to receive(:error).with("[Slack] Failed to send message after 3 retries")
          described_class.send(:send_message, message, channel: channel)
        end

        it "sends final failure to Sentry" do
          allow(Sentry).to receive(:with_scope) do |&block|
            block.call(double("Scope", set_tag: nil, set_context: nil))
          end
          allow(Sentry).to receive(:capture_exception)
          # Mock sleep to avoid actual delays in tests
          allow(described_class).to receive(:sleep).and_return(true)
          expect(Sentry).to receive(:capture_message).with("Slack message failed after max retries", level: "error")
          described_class.send(:send_message, message, channel: channel)
        end

        it "returns false" do
          allow(described_class).to receive(:client).and_return(mock_client)
          # Mock sleep to avoid actual delays in tests
          allow(described_class).to receive(:sleep).and_return(true)
          result = described_class.send(:send_message, message, channel: channel)
          expect(result).to be false
        end
      end
    end
  end

  describe "message formatting methods" do
    describe "#format_signal_message" do
      let(:signal_data) do
        {
          symbol: "BTC-USD",
          side: "long",
          price: 50_000.0,
          quantity: 1,
          tp: 52_000.0,
          sl: 49_000.0,
          confidence: 80
        }
      end

      it "returns properly formatted message" do
        result = described_class.send(:format_signal_message, signal_data)

        expect(result[:text]).to eq("\u{1F3AF} New Trading Signal: BTC-USD")
        expect(result[:attachments]).to be_an(Array)
        expect(result[:attachments].first[:fields]).to include(
          {title: "Symbol", value: "BTC-USD", short: true},
          {title: "Side", value: "LONG", short: true},
          {title: "Price", value: "$50000.0", short: true}
        )
      end

      it "handles missing data gracefully" do
        result = described_class.send(:format_signal_message, {})
        expect(result[:text]).to eq("\u{1F3AF} New Trading Signal: N/A")
      end

      it "formats colors correctly" do
        long_signal = signal_data.merge(side: "long")
        result = described_class.send(:format_signal_message, long_signal)
        expect(result[:attachments].first[:color]).to eq("good")

        short_signal = signal_data.merge(side: "short")
        result = described_class.send(:format_signal_message, short_signal)
        expect(result[:attachments].first[:color]).to eq("danger")
      end
    end

    describe "#format_position_message" do
      let(:mock_position) do
        double("Position",
          product_id: "BTC-USD",
          side: "long",
          size: 1,
          entry_price: 50_000.0,
          pnl: 100.0,
          entry_time: 1.hour.ago,
          close_time: Time.current)
      end

      it "returns properly formatted message" do
        result = described_class.send(:format_position_message, mock_position, "closed")

        expect(result[:text]).to eq("\u{1F534} Position Closed: BTC-USD")
        expect(result[:attachments]).to be_an(Array)
        expect(result[:attachments].first[:fields]).to include(
          {title: "Symbol", value: "BTC-USD", short: true},
          {title: "Side", value: "LONG", short: true}
        )
      end

      it "includes PnL information when available" do
        result = described_class.send(:format_position_message, mock_position, "closed")
        pnl_field = result[:attachments].first[:fields].find { |f| f[:title] == "PnL" }
        expect(pnl_field[:value]).to eq("$100.0")
      end

      it "formats duration correctly" do
        result = described_class.send(:format_position_message, mock_position, "closed")
        duration_field = result[:attachments].first[:fields].find { |f| f[:title] == "Duration" }
        expect(duration_field[:value]).to match(/\d+h \d+m/)
      end
    end

    describe "#format_alert_message" do
      it "formats critical alerts correctly" do
        result = described_class.send(:format_alert_message, "critical", "System Down", "Database connection failed")

        expect(result[:text]).to eq("\u{1F6A8} Alert: System Down")
        expect(result[:attachments].first[:color]).to eq("danger")
        expect(result[:attachments].first[:fields]).to include(
          {title: "Level", value: "CRITICAL", short: true},
          {title: "Details", value: "Database connection failed", short: false}
        )
      end

      it "handles alerts without details" do
        result = described_class.send(:format_alert_message, "warning", "High CPU Usage", nil)

        expect(result[:text]).to eq("\u26A0\uFE0F Alert: High CPU Usage")
        expect(result[:attachments].first[:color]).to eq("warning")
      end
    end

    describe "#format_health_message" do
      let(:health_data) do
        {
          overall_health: "healthy",
          database: true,
          coinbase_api: true,
          background_jobs: true,
          websocket_connections: 5
        }
      end

      it "formats healthy status correctly" do
        result = described_class.send(:format_health_message, health_data)

        expect(result[:text]).to eq("\u2705 Health Check")
        expect(result[:attachments].first[:color]).to eq("good")
        expect(result[:attachments].first[:fields]).to include(
          {title: "Overall Health", value: "Healthy", short: true},
          {title: "Database", value: "\u2705", short: true}
        )
      end

      it "formats unhealthy status correctly" do
        unhealthy_data = health_data.merge(overall_health: "unhealthy", database: false)
        result = described_class.send(:format_health_message, unhealthy_data)

        expect(result[:text]).to eq("\u274C Health Check")
        expect(result[:attachments].first[:color]).to eq("danger")
        expect(result[:attachments].first[:fields].find { |f| f[:title] == "Database" }[:value]).to eq("\u274C")
      end
    end

    describe "#duration_in_words" do
      it "formats hours and minutes correctly" do
        start_time = Time.current - 2.hours - 30.minutes
        end_time = Time.current

        result = described_class.send(:duration_in_words, start_time, end_time)
        expect(result).to eq("2h 30m")
      end

      it "formats only minutes when less than an hour" do
        start_time = Time.current - 45.minutes
        end_time = Time.current

        result = described_class.send(:duration_in_words, start_time, end_time)
        expect(result).to eq("45m")
      end

      it "returns N/A for invalid times" do
        result = described_class.send(:duration_in_words, nil, nil)
        expect(result).to eq("N/A")
      end
    end
  end

  describe "Sentry integration" do
    it "includes SentryServiceTracking" do
      expect(described_class.ancestors).to include(SentryServiceTracking)
    end
  end
end
