# frozen_string_literal: true

require "rails_helper"

RSpec.describe SignalsChannel, type: :channel do
  let(:user) { double("User") }
  let(:logger) { instance_double(Logger) }

  before(:each) do
    allow(Rails).to receive(:logger).and_return(logger)
    allow(logger).to receive(:info)
  end

  describe "#subscribed" do
    context "with no parameters" do
      it "subscribes to general signals stream" do
        subscribe

        expect(subscription).to have_stream_from("signals")
      end

      it "subscribes to signal_stats stream" do
        subscribe

        expect(subscription).to have_stream_from("signal_stats")
      end

      it "subscribes to signal_status stream" do
        subscribe

        expect(subscription).to have_stream_from("signal_status")
      end

      it "transmits welcome message" do
        subscribe

        expect(transmissions.last).to include(
          "type" => "connection_established",
          "message" => "Connected to SignalsChannel",
          "subscriptions" => "signals, signal_stats, signal_status"
        )
      end

      it "includes timestamp in welcome message" do
        subscribe

        timestamp = transmissions.last["timestamp"]
        expect { Time.iso8601(timestamp) }.not_to raise_error
      end
    end

    context "with symbol parameter" do
      it "subscribes to symbol-specific stream" do
        subscribe(symbol: "BTC-USD")

        expect(subscription).to have_stream_from("signals:BTC-USD")
      end

      it "includes symbol in subscription info" do
        subscribe(symbol: "BTC-USD")

        expect(transmissions.last["subscriptions"]).to eq("signals, signals:BTC-USD, signal_stats, signal_status")
      end
    end

    context "with strategy parameter" do
      it "subscribes to strategy-specific stream" do
        subscribe(strategy: "MultiTimeframeSignal")

        expect(subscription).to have_stream_from("signals:strategy:MultiTimeframeSignal")
      end

      it "includes strategy in subscription info" do
        subscribe(strategy: "MultiTimeframeSignal")

        expect(transmissions.last["subscriptions"]).to eq("signals, signals:strategy:MultiTimeframeSignal, signal_stats, signal_status")
      end
    end

    context "with both symbol and strategy parameters" do
      it "subscribes to both specific streams" do
        subscribe(symbol: "BTC-USD", strategy: "MultiTimeframeSignal")

        expect(subscription).to have_stream_from("signals:BTC-USD")
        expect(subscription).to have_stream_from("signals:strategy:MultiTimeframeSignal")
      end

      it "includes both in subscription info" do
        subscribe(symbol: "BTC-USD", strategy: "MultiTimeframeSignal")

        expect(transmissions.last["subscriptions"]).to eq("signals, signals:BTC-USD, signals:strategy:MultiTimeframeSignal, signal_stats, signal_status")
      end
    end
  end

  describe "#unsubscribed" do
    it "logs client disconnection" do
      subscribe

      expect(logger).to receive(:info).with("[SignalsChannel] Client disconnected from signals, signal_stats, signal_status")

      unsubscribe
    end

    context "with symbol parameter" do
      it "logs disconnection with symbol info" do
        subscribe(symbol: "BTC-USD")

        expect(logger).to receive(:info).with("[SignalsChannel] Client disconnected from signals, signals:BTC-USD, signal_stats, signal_status")

        unsubscribe
      end
    end

    context "with strategy parameter" do
      it "logs disconnection with strategy info" do
        subscribe(strategy: "MultiTimeframeSignal")

        expect(logger).to receive(:info).with("[SignalsChannel] Client disconnected from signals, signals:strategy:MultiTimeframeSignal, signal_stats, signal_status")

        unsubscribe
      end
    end
  end

  describe "#get_active_signals" do
    let!(:active_signal) { create(:signal_alert, alert_status: "active", confidence: 85) }
    let!(:expired_signal) { create(:signal_alert, alert_status: "expired") }

    before do
      subscribe
    end

    context "without limit parameter" do
      it "returns active signals with default limit" do
        perform :get_active_signals, {}

        expect(transmissions.last).to include(
          "type" => "active_signals_response",
          "signals" => [a_hash_including("id" => active_signal.id, "confidence" => 85)]
        )
        expect(transmissions.last["signals"].length).to eq(1)
      end
    end

    context "with limit parameter" do
      let!(:another_active_signal) { create(:signal_alert, alert_status: "active", confidence: 90) }

      it "respects the limit parameter" do
        perform :get_active_signals, {"limit" => 1}

        expect(transmissions.last["signals"].length).to eq(1)
      end

      it "returns highest confidence signals first" do
        perform :get_active_signals, {"limit" => 2}

        confidences = transmissions.last["signals"].map { |s| s["confidence"] }
        expect(confidences).to eq([90, 85])
      end
    end

    it "includes timestamp in response" do
      perform :get_active_signals, {}

      timestamp = transmissions.last["timestamp"]
      expect { Time.iso8601(timestamp) }.not_to raise_error
    end

    it "does not include expired signals" do
      perform :get_active_signals, {}

      signal_ids = transmissions.last["signals"].map { |s| s["id"] }
      expect(signal_ids).to include(active_signal.id)
      expect(signal_ids).not_to include(expired_signal.id)
    end
  end

  describe "#get_stats" do
    let!(:active_signal) { create(:signal_alert, alert_status: "active", confidence: 80) }
    let!(:high_conf_signal) { create(:signal_alert, alert_timestamp: 1.hour.ago, confidence: 85) }
    let!(:recent_signal) { create(:signal_alert, alert_timestamp: 30.minutes.ago, confidence: 70) }
    let!(:old_signal) { create(:signal_alert, alert_timestamp: 25.hours.ago, confidence: 75) }

    before do
      subscribe
    end

    context "without hours parameter" do
      it "returns stats for default 24 hour period" do
        perform :get_stats, {}

        expect(transmissions.last).to include(
          "type" => "stats_response",
          "time_range_hours" => 24
        )
        stats = transmissions.last["stats"]
        expect(stats["active_signals"]).to eq(4) # All 4 signals are active
        expect(stats["recent_signals"]).to eq(3) # 3 signals within 24 hours (old_signal is 25 hours ago)
        expect(stats["high_confidence_signals"]).to eq(3) # 3 signals with confidence >= 70
      end
    end

    context "with hours parameter" do
      it "returns stats for specified time period" do
        perform :get_stats, {"hours" => 2}

        expect(transmissions.last["time_range_hours"]).to eq(2)
        # Should include signals created within the last 2 hours
        recent_count = transmissions.last["stats"]["recent_signals"]
        expect(recent_count).to eq(3) # active_signal, recent_signal, high_conf_signal (all within 2 hours)
      end
    end

    it "includes timestamp in response" do
      perform :get_stats, {}

      timestamp = transmissions.last["timestamp"]
      expect { Time.iso8601(timestamp) }.not_to raise_error
    end

    it "includes signals grouped by symbol" do
      active_signal.update(symbol: "BTC-USD")
      recent_signal.update(symbol: "ETH-USD")
      high_conf_signal.update(symbol: "BTC-USD")

      perform :get_stats, {}

      expect(transmissions.last["stats"]["signals_by_symbol"]).to include("BTC-USD" => 2) # BTC signals within time range
      expect(transmissions.last["stats"]["signals_by_symbol"]).to include("ETH-USD" => 1)
    end

    it "includes signals grouped by strategy" do
      active_signal.update(strategy_name: "StrategyA")
      recent_signal.update(strategy_name: "StrategyB")
      high_conf_signal.update(strategy_name: "StrategyA")

      perform :get_stats, {}

      expect(transmissions.last["stats"]["signals_by_strategy"]).to include("StrategyA" => 2) # StrategyA signals within time range
      expect(transmissions.last["stats"]["signals_by_strategy"]).to include("StrategyB" => 1)
    end
  end

  describe "#subscription_info" do
    it "returns general subscription info" do
      subscribe

      expect(subscription.instance_eval { subscription_info }).to eq("signals, signal_stats, signal_status")
    end

    context "with symbol parameter" do
      it "includes symbol-specific subscription" do
        subscribe(symbol: "BTC-USD")

        expect(subscription.instance_eval do
          subscription_info
        end).to eq("signals, signals:BTC-USD, signal_stats, signal_status")
      end
    end

    context "with strategy parameter" do
      it "includes strategy-specific subscription" do
        subscribe(strategy: "MultiTimeframeSignal")

        expect(subscription.instance_eval do
          subscription_info
        end).to eq("signals, signals:strategy:MultiTimeframeSignal, signal_stats, signal_status")
      end
    end

    context "with both parameters" do
      it "includes both specific subscriptions" do
        subscribe(symbol: "BTC-USD", strategy: "MultiTimeframeSignal")

        expect(subscription.instance_eval do
          subscription_info
        end).to eq("signals, signals:BTC-USD, signals:strategy:MultiTimeframeSignal, signal_stats, signal_status")
      end
    end
  end

  describe "channel configuration" do
    it "inherits from ApplicationCable::Channel" do
      expect(described_class.superclass).to eq(ApplicationCable::Channel)
    end
  end

  describe "message handling" do
    before do
      subscribe
    end

    it "handles get_active_signals action" do
      expect(subscription).to respond_to(:get_active_signals)
    end

    it "handles get_stats action" do
      expect(subscription).to respond_to(:get_stats)
    end

    it "transmits responses via Action Cable" do
      perform :get_active_signals, {}

      expect(transmissions).to_not be_empty
      expect(transmissions.last["type"]).to eq("active_signals_response")
    end
  end

  describe "error handling" do
    before do
      subscribe
    end

    context "when database query fails" do
      before do
        allow(SignalAlert).to receive(:active).and_raise(StandardError.new("Database error"))
      end

      it "raises the error" do
        expect { perform :get_active_signals, {} }.to_not raise_error

        # The service now catches errors and sends error responses instead of raising
        expect(transmissions.last["type"]).to eq("error")
        expect(transmissions.last["message"]).to eq("Failed to retrieve active signals")
      end
    end
  end

  describe "real-time broadcasting integration" do
    it "can receive broadcasts on general signals stream" do
      subscribe

      expect(subscription).to have_stream_from("signals")
    end

    it "can receive broadcasts on symbol-specific streams" do
      subscribe(symbol: "BTC-USD")

      expect(subscription).to have_stream_from("signals:BTC-USD")
    end

    it "can receive broadcasts on strategy-specific streams" do
      subscribe(strategy: "MultiTimeframeSignal")

      expect(subscription).to have_stream_from("signals:strategy:MultiTimeframeSignal")
    end

    it "can receive broadcasts on stats stream" do
      subscribe

      expect(subscription).to have_stream_from("signal_stats")
    end

    it "can receive broadcasts on status stream" do
      subscribe

      expect(subscription).to have_stream_from("signal_status")
    end
  end
end
