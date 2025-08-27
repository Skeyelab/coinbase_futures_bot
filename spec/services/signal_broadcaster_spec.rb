# frozen_string_literal: true

require "rails_helper"

RSpec.describe SignalBroadcaster, type: :service do
  let(:mock_action_cable) { instance_double(ActionCable::Server::Base) }

  before do
    allow(ActionCable).to receive(:server).and_return(mock_action_cable)
    allow(mock_action_cable).to receive(:broadcast)
    allow(Rails).to receive(:logger).and_return(instance_double(Logger))
    allow(Rails.logger).to receive(:info)
    allow(Rails.logger).to receive(:error)
  end

  describe ".broadcast" do
    let(:signal_data) do
      {
        id: 123,
        symbol: "BTC-USD",
        side: "long",
        signal_type: "entry",
        strategy_name: "MultiTimeframeSignal",
        confidence: 75,
        price: 50_000,
        sl: 49_000,
        tp: 52_000,
        quantity: 10,
        timeframe: "15m",
        metadata: {"test" => "metadata"},
        strategy_data: {"ema_short" => 49_900, "ema_long" => 49_800}
      }
    end

    context "when broadcasting is enabled" do
      before do
        allow(ENV).to receive(:fetch).with("SIGNAL_BROADCAST_ENABLED", "true").and_return("true")
      end

      it "broadcasts to general signals channel" do
        expect(mock_action_cable).to receive(:broadcast).with("signals", anything)

        described_class.broadcast(signal_data)
      end

      it "broadcasts to symbol-specific channel" do
        expect(mock_action_cable).to receive(:broadcast).with("signals:BTC-USD", anything)

        described_class.broadcast(signal_data)
      end

      it "broadcasts to strategy-specific channel" do
        expect(mock_action_cable).to receive(:broadcast).with("signals:strategy:MultiTimeframeSignal", anything)

        described_class.broadcast(signal_data)
      end

      it "formats the signal payload correctly" do
        formatted_payload = nil
        allow(mock_action_cable).to receive(:broadcast) do |channel, payload|
          formatted_payload = payload if channel == "signals"
        end

        described_class.broadcast(signal_data)

        expect(formatted_payload).to include(
          type: "signal_alert",
          timestamp: anything,
          signal: hash_including(
            id: 123,
            symbol: "BTC-USD",
            side: "long",
            signal_type: "entry",
            strategy_name: "MultiTimeframeSignal",
            confidence: 75,
            entry_price: 50_000,
            stop_loss: 49_000,
            take_profit: 52_000,
            quantity: 10,
            timeframe: "15m",
            alert_status: "active",
            metadata: {"test" => "metadata"},
            strategy_data: {"ema_short" => 49_900, "ema_long" => 49_800}
          )
        )
      end

      it "logs successful broadcast" do
        expect(Rails.logger).to receive(:info).with("[SignalBroadcaster] Broadcast signal: BTC-USD long@50000")

        described_class.broadcast(signal_data)
      end

      it "handles signals without symbol" do
        signal_without_symbol = signal_data.except(:symbol)

        expect(mock_action_cable).to receive(:broadcast).with("signals", anything)
        expect(mock_action_cable).not_to receive(:broadcast).with(/^signals:[^s]/, anything)

        described_class.broadcast(signal_without_symbol)
      end

      it "handles signals without strategy_name" do
        signal_without_strategy = signal_data.except(:strategy_name)

        expect(mock_action_cable).to receive(:broadcast).with("signals", anything)
        expect(mock_action_cable).to receive(:broadcast).with("signals:BTC-USD", anything)
        expect(mock_action_cable).not_to receive(:broadcast).with(/^signals:strategy:/, anything)

        described_class.broadcast(signal_without_strategy)
      end

      it "calculates correct expiry for different timeframes" do
        formatted_payload = nil
        allow(mock_action_cable).to receive(:broadcast) do |channel, payload|
          formatted_payload = payload if channel == "signals"
        end

        described_class.broadcast(signal_data)

        expected_expiry = 15.minutes.from_now.utc.iso8601
        expect(formatted_payload[:signal][:expires_at]).to eq(expected_expiry)
      end
    end

    context "when broadcasting is disabled" do
      before do
        allow(ENV).to receive(:fetch).with("SIGNAL_BROADCAST_ENABLED", "true").and_return("false")
      end

      it "does not broadcast signals" do
        expect(mock_action_cable).not_to receive(:broadcast)

        described_class.broadcast(signal_data)
      end

      it "returns early without processing" do
        expect(described_class).not_to receive(:format_signal_payload)

        described_class.broadcast(signal_data)
      end
    end

    context "when broadcasting fails" do
      before do
        allow(ENV).to receive(:fetch).with("SIGNAL_BROADCAST_ENABLED", "true").and_return("true")
        allow(mock_action_cable).to receive(:broadcast).and_raise(StandardError.new("Broadcast failed"))
      end

      it "logs the error" do
        expect(Rails.logger).to receive(:error).with("[SignalBroadcaster] Failed to broadcast signal: Broadcast failed")

        described_class.broadcast(signal_data)
      end

      it "does not raise the error" do
        expect { described_class.broadcast(signal_data) }.not_to raise_error
      end
    end
  end

  describe ".broadcast_stats" do
    let(:stats_data) do
      {
        total_signals: 150,
        active_signals: 25,
        success_rate: 68.5,
        avg_confidence: 72.3
      }
    end

    context "when broadcasting is enabled" do
      before do
        allow(ENV).to receive(:fetch).with("SIGNAL_BROADCAST_ENABLED", "true").and_return("true")
      end

      it "broadcasts to signal_stats channel" do
        expect(mock_action_cable).to receive(:broadcast).with("signal_stats", anything)

        described_class.broadcast_stats(stats_data)
      end

      it "formats the stats payload correctly" do
        formatted_payload = nil
        allow(mock_action_cable).to receive(:broadcast) do |channel, payload|
          formatted_payload = payload if channel == "signal_stats"
        end

        described_class.broadcast_stats(stats_data)

        expect(formatted_payload).to include(
          type: "stats_update",
          timestamp: anything,
          stats: stats_data
        )
      end
    end

    context "when broadcasting is disabled" do
      before do
        allow(ENV).to receive(:fetch).with("SIGNAL_BROADCAST_ENABLED", "true").and_return("false")
      end

      it "does not broadcast stats" do
        expect(mock_action_cable).not_to receive(:broadcast)

        described_class.broadcast_stats(stats_data)
      end
    end

    context "when broadcasting fails" do
      before do
        allow(ENV).to receive(:fetch).with("SIGNAL_BROADCAST_ENABLED", "true").and_return("true")
        allow(mock_action_cable).to receive(:broadcast).and_raise(StandardError.new("Stats broadcast failed"))
      end

      it "logs the error" do
        expect(Rails.logger).to receive(:error).with("[SignalBroadcaster] Failed to broadcast stats: Stats broadcast failed")

        described_class.broadcast_stats(stats_data)
      end
    end
  end

  describe ".broadcast_status" do
    let(:status_data) do
      {
        system_status: "operational",
        last_evaluation: Time.current.utc.iso8601,
        active_connections: 15,
        queue_depth: 3
      }
    end

    context "when broadcasting is enabled" do
      before do
        allow(ENV).to receive(:fetch).with("SIGNAL_BROADCAST_ENABLED", "true").and_return("true")
      end

      it "broadcasts to signal_status channel" do
        expect(mock_action_cable).to receive(:broadcast).with("signal_status", anything)

        described_class.broadcast_status(status_data)
      end

      it "formats the status payload correctly" do
        formatted_payload = nil
        allow(mock_action_cable).to receive(:broadcast) do |channel, payload|
          formatted_payload = payload if channel == "signal_status"
        end

        described_class.broadcast_status(status_data)

        expect(formatted_payload).to include(
          type: "status_update",
          timestamp: anything,
          status: status_data
        )
      end
    end

    context "when broadcasting is disabled" do
      before do
        allow(ENV).to receive(:fetch).with("SIGNAL_BROADCAST_ENABLED", "true").and_return("false")
      end

      it "does not broadcast status" do
        expect(mock_action_cable).not_to receive(:broadcast)

        described_class.broadcast_status(status_data)
      end
    end

    context "when broadcasting fails" do
      before do
        allow(ENV).to receive(:fetch).with("SIGNAL_BROADCAST_ENABLED", "true").and_return("true")
        allow(mock_action_cable).to receive(:broadcast).and_raise(StandardError.new("Status broadcast failed"))
      end

      it "logs the error" do
        expect(Rails.logger).to receive(:error).with("[SignalBroadcaster] Failed to broadcast status: Status broadcast failed")

        described_class.broadcast_status(status_data)
      end
    end
  end

  describe ".enabled?" do
    it "returns true when SIGNAL_BROADCAST_ENABLED is true" do
      allow(ENV).to receive(:fetch).with("SIGNAL_BROADCAST_ENABLED", "true").and_return("true")

      expect(described_class.send(:enabled?)).to be true
    end

    it "returns true when SIGNAL_BROADCAST_ENABLED is TRUE (case insensitive)" do
      allow(ENV).to receive(:fetch).with("SIGNAL_BROADCAST_ENABLED", "true").and_return("TRUE")

      expect(described_class.send(:enabled?)).to be true
    end

    it "returns false when SIGNAL_BROADCAST_ENABLED is false" do
      allow(ENV).to receive(:fetch).with("SIGNAL_BROADCAST_ENABLED", "true").and_return("false")

      expect(described_class.send(:enabled?)).to be false
    end

    it "returns false when SIGNAL_BROADCAST_ENABLED is FALSE (case insensitive)" do
      allow(ENV).to receive(:fetch).with("SIGNAL_BROADCAST_ENABLED", "true").and_return("FALSE")

      expect(described_class.send(:enabled?)).to be false
    end

    it "defaults to true when SIGNAL_BROADCAST_ENABLED is not set" do
      allow(ENV).to receive(:fetch).with("SIGNAL_BROADCAST_ENABLED", "true").and_return("true")

      expect(described_class.send(:enabled?)).to be true
    end
  end

  describe ".format_signal_payload" do
    let(:signal_data) do
      {
        symbol: "BTC-USD",
        side: "long",
        strategy_name: "MultiTimeframeSignal",
        confidence: 80,
        price: 50_000,
        sl: 49_000,
        tp: 52_000,
        quantity: 5,
        timeframe: "1h"
      }
    end

    it "formats the signal data correctly" do
      payload = described_class.send(:format_signal_payload, signal_data)

      expect(payload).to include(
        type: "signal_alert",
        timestamp: anything
      )

      expect(payload[:signal]).to include(
        symbol: "BTC-USD",
        side: "long",
        signal_type: "entry",
        strategy_name: "MultiTimeframeSignal",
        confidence: 80,
        entry_price: 50_000,
        stop_loss: 49_000,
        take_profit: 52_000,
        quantity: 5,
        timeframe: "1h",
        alert_status: "active"
      )
    end

    it "includes timestamps in ISO format" do
      payload = described_class.send(:format_signal_payload, signal_data)

      expect(payload[:timestamp]).to match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/)
      expect(payload[:signal][:alert_timestamp]).to match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/)
    end

    it "provides default values for missing data" do
      minimal_signal = {symbol: "BTC-USD", side: "long"}
      payload = described_class.send(:format_signal_payload, minimal_signal)

      expect(payload[:signal]).to include(
        signal_type: "entry",
        metadata: {},
        strategy_data: {}
      )
    end
  end

  describe ".calculate_expiry" do
    context "with MultiTimeframeSignal strategy" do
      it "calculates 2 minutes expiry for 1m timeframe" do
        expiry = described_class.send(:calculate_expiry, "MultiTimeframeSignal", "1m")
        expected = 2.minutes.from_now.utc.iso8601
        expect(expiry).to eq(expected)
      end

      it "calculates 5 minutes expiry for 5m timeframe" do
        expiry = described_class.send(:calculate_expiry, "MultiTimeframeSignal", "5m")
        expected = 5.minutes.from_now.utc.iso8601
        expect(expiry).to eq(expected)
      end

      it "calculates 15 minutes expiry for 15m timeframe" do
        expiry = described_class.send(:calculate_expiry, "MultiTimeframeSignal", "15m")
        expected = 15.minutes.from_now.utc.iso8601
        expect(expiry).to eq(expected)
      end

      it "calculates 1 hour expiry for 1h timeframe" do
        expiry = described_class.send(:calculate_expiry, "MultiTimeframeSignal", "1h")
        expected = 1.hour.from_now.utc.iso8601
        expect(expiry).to eq(expected)
      end

      it "calculates 30 minutes expiry for unknown timeframe" do
        expiry = described_class.send(:calculate_expiry, "MultiTimeframeSignal", "4h")
        expected = 30.minutes.from_now.utc.iso8601
        expect(expiry).to eq(expected)
      end
    end

    context "with other strategies" do
      it "calculates 15 minutes expiry for non-MultiTimeframeSignal strategies" do
        expiry = described_class.send(:calculate_expiry, "CustomStrategy", "15m")
        expected = 15.minutes.from_now.utc.iso8601
        expect(expiry).to eq(expected)
      end
    end
  end

  describe "integration with different signal types" do
    let(:long_signal) do
      {
        symbol: "BTC-USD",
        side: "long",
        strategy_name: "MultiTimeframeSignal",
        confidence: 85,
        price: 50_000,
        sl: 49_000,
        tp: 52_000,
        quantity: 10,
        timeframe: "15m"
      }
    end

    let(:short_signal) do
      {
        symbol: "ETH-USD",
        side: "short",
        strategy_name: "MultiTimeframeSignal",
        confidence: 78,
        price: 3_000,
        sl: 3_100,
        tp: 2_900,
        quantity: 5,
        timeframe: "5m"
      }
    end

    before do
      allow(ENV).to receive(:fetch).with("SIGNAL_BROADCAST_ENABLED", "true").and_return("true")
    end

    it "handles long signals correctly" do
      expect(mock_action_cable).to receive(:broadcast).with("signals", anything)
      expect(mock_action_cable).to receive(:broadcast).with("signals:BTC-USD", anything)
      expect(mock_action_cable).to receive(:broadcast).with("signals:strategy:MultiTimeframeSignal", anything)

      described_class.broadcast(long_signal)
    end

    it "handles short signals correctly" do
      expect(mock_action_cable).to receive(:broadcast).with("signals", anything)
      expect(mock_action_cable).to receive(:broadcast).with("signals:ETH-USD", anything)
      expect(mock_action_cable).to receive(:broadcast).with("signals:strategy:MultiTimeframeSignal", anything)

      described_class.broadcast(short_signal)
    end

    it "logs different signal types appropriately" do
      expect(Rails.logger).to receive(:info).with("[SignalBroadcaster] Broadcast signal: BTC-USD long@50000")
      described_class.broadcast(long_signal)

      expect(Rails.logger).to receive(:info).with("[SignalBroadcaster] Broadcast signal: ETH-USD short@3000")
      described_class.broadcast(short_signal)
    end
  end
end
