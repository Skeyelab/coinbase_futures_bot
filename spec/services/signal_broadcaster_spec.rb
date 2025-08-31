# frozen_string_literal: true

require "rails_helper"

RSpec.describe SignalBroadcaster, type: :service do
  let(:mock_action_cable) { double("ActionCable::Server") }
  let(:signal_data) do
    {
      id: 123,
      symbol: "BTC-USD",
      side: "long",
      signal_type: "entry",
      strategy_name: "MultiTimeframeSignal",
      confidence: 85,
      price: 50_000.0,
      sl: 49_000.0,
      tp: 52_000.0,
      quantity: 1,
      timeframe: "1h",
      metadata: {custom_field: "value"},
      strategy_data: {indicator_data: "data"}
    }
  end

  before do
    allow(ActionCable).to receive(:server).and_return(mock_action_cable)
    allow(mock_action_cable).to receive(:broadcast)
    allow(Rails.logger).to receive(:info)
    allow(Rails.logger).to receive(:error)
  end

  describe ".broadcast" do
    context "when broadcasting is enabled" do
      before do
        allow(ENV).to receive(:fetch).with("SIGNAL_BROADCAST_ENABLED", "true").and_return("true")
      end

      it "formats the signal payload" do
        expect(described_class).to receive(:format_signal_payload).with(signal_data)
        described_class.broadcast(signal_data)
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

      it "logs successful broadcast" do
        expect(Rails.logger).to receive(:info).with("[SignalBroadcaster] Broadcast signal: BTC-USD long@50000.0")
        described_class.broadcast(signal_data)
      end

      context "when symbol is missing" do
        let(:signal_data_without_symbol) { signal_data.except(:symbol) }

        it "does not broadcast to symbol-specific channel" do
          expect(mock_action_cable).not_to receive(:broadcast).with(/signals:[^s]/, anything)
          described_class.broadcast(signal_data_without_symbol)
        end
      end

      context "when strategy_name is missing" do
        let(:signal_data_without_strategy) { signal_data.except(:strategy_name) }

        it "does not broadcast to strategy-specific channel" do
          expect(mock_action_cable).not_to receive(:broadcast).with(/signals:strategy:/, anything)
          described_class.broadcast(signal_data_without_strategy)
        end
      end

      context "when broadcasting fails" do
        before do
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

    context "when broadcasting is disabled" do
      before do
        allow(ENV).to receive(:fetch).with("SIGNAL_BROADCAST_ENABLED", "true").and_return("false")
      end

      it "returns early without broadcasting" do
        expect(mock_action_cable).not_to receive(:broadcast)
        described_class.broadcast(signal_data)
      end

      it "does not log anything" do
        expect(Rails.logger).not_to receive(:info)
        described_class.broadcast(signal_data)
      end
    end
  end

  describe ".broadcast_stats" do
    let(:stats_data) do
      {
        total_signals: 150,
        successful_trades: 120,
        win_rate: 80.0,
        average_profit: 250.0
      }
    end

    context "when broadcasting is enabled" do
      before do
        allow(ENV).to receive(:fetch).with("SIGNAL_BROADCAST_ENABLED", "true").and_return("true")
      end

      it "broadcasts to signal_stats channel" do
        expect(mock_action_cable).to receive(:broadcast).with("signal_stats", {
          type: "stats_update",
          timestamp: an_instance_of(String),
          stats: stats_data
        })
        described_class.broadcast_stats(stats_data)
      end

      it "includes current timestamp in ISO format" do
        allow(Time).to receive(:current).and_return(Time.new(2024, 1, 15, 14, 30, 0, "+00:00"))

        expected_payload = {
          type: "stats_update",
          timestamp: "2024-01-15T14:30:00Z",
          stats: stats_data
        }

        expect(mock_action_cable).to receive(:broadcast).with("signal_stats", expected_payload)
        described_class.broadcast_stats(stats_data)
      end

      context "when broadcasting fails" do
        before do
          allow(mock_action_cable).to receive(:broadcast).and_raise(StandardError.new("Stats broadcast failed"))
        end

        it "logs the error" do
          expect(Rails.logger).to receive(:error).with("[SignalBroadcaster] Failed to broadcast stats: Stats broadcast failed")
          described_class.broadcast_stats(stats_data)
        end
      end
    end

    context "when broadcasting is disabled" do
      before do
        allow(ENV).to receive(:fetch).with("SIGNAL_BROADCAST_ENABLED", "true").and_return("false")
      end

      it "returns early without broadcasting" do
        expect(mock_action_cable).not_to receive(:broadcast)
        described_class.broadcast_stats(stats_data)
      end
    end
  end

  describe ".broadcast_status" do
    let(:status_data) do
      {
        trading_active: true,
        open_positions: 5,
        daily_pnl: 1250.0,
        health_status: "healthy"
      }
    end

    context "when broadcasting is enabled" do
      before do
        allow(ENV).to receive(:fetch).with("SIGNAL_BROADCAST_ENABLED", "true").and_return("true")
      end

      it "broadcasts to signal_status channel" do
        expect(mock_action_cable).to receive(:broadcast).with("signal_status", {
          type: "status_update",
          timestamp: an_instance_of(String),
          status: status_data
        })
        described_class.broadcast_status(status_data)
      end

      it "includes current timestamp in ISO format" do
        allow(Time).to receive(:current).and_return(Time.new(2024, 1, 15, 16, 45, 0, "+00:00"))

        expected_payload = {
          type: "status_update",
          timestamp: "2024-01-15T16:45:00Z",
          status: status_data
        }

        expect(mock_action_cable).to receive(:broadcast).with("signal_status", expected_payload)
        described_class.broadcast_status(status_data)
      end

      context "when broadcasting fails" do
        before do
          allow(mock_action_cable).to receive(:broadcast).and_raise(StandardError.new("Status broadcast failed"))
        end

        it "logs the error" do
          expect(Rails.logger).to receive(:error).with("[SignalBroadcaster] Failed to broadcast status: Status broadcast failed")
          described_class.broadcast_status(status_data)
        end
      end
    end

    context "when broadcasting is disabled" do
      before do
        allow(ENV).to receive(:fetch).with("SIGNAL_BROADCAST_ENABLED", "true").and_return("false")
      end

      it "returns early without broadcasting" do
        expect(mock_action_cable).not_to receive(:broadcast)
        described_class.broadcast_status(status_data)
      end
    end
  end

  describe ".enabled?" do
    context "when SIGNAL_BROADCAST_ENABLED is true" do
      before do
        allow(ENV).to receive(:fetch).with("SIGNAL_BROADCAST_ENABLED", "true").and_return("true")
      end

      it "returns true" do
        expect(described_class.send(:enabled?)).to be true
      end
    end

    context "when SIGNAL_BROADCAST_ENABLED is TRUE" do
      before do
        allow(ENV).to receive(:fetch).with("SIGNAL_BROADCAST_ENABLED", "true").and_return("TRUE")
      end

      it "returns true (case insensitive)" do
        expect(described_class.send(:enabled?)).to be true
      end
    end

    context "when SIGNAL_BROADCAST_ENABLED is false" do
      before do
        allow(ENV).to receive(:fetch).with("SIGNAL_BROADCAST_ENABLED", "true").and_return("false")
      end

      it "returns false" do
        expect(described_class.send(:enabled?)).to be false
      end
    end

    context "when SIGNAL_BROADCAST_ENABLED is not set" do
      before do
        allow(ENV).to receive(:fetch).with("SIGNAL_BROADCAST_ENABLED", "true").and_return("true")
      end

      it "returns true (default)" do
        expect(described_class.send(:enabled?)).to be true
      end
    end
  end

  describe ".format_signal_payload" do
    let(:formatted_payload) { described_class.send(:format_signal_payload, signal_data) }

    it "returns properly formatted payload" do
      expect(formatted_payload).to include(
        type: "signal_alert",
        timestamp: an_instance_of(String),
        signal: hash_including(
          id: 123,
          symbol: "BTC-USD",
          side: "long",
          signal_type: "entry",
          strategy_name: "MultiTimeframeSignal",
          confidence: 85,
          entry_price: 50_000.0,
          stop_loss: 49_000.0,
          take_profit: 52_000.0,
          quantity: 1,
          timeframe: "1h",
          alert_status: "active",
          alert_timestamp: an_instance_of(String),
          expires_at: an_instance_of(String),
          metadata: {custom_field: "value"},
          strategy_data: {indicator_data: "data"}
        )
      )
    end

    it "includes current timestamp" do
      allow(Time).to receive(:current).and_return(Time.new(2024, 1, 15, 14, 30, 0, "+00:00"))

      expect(formatted_payload[:timestamp]).to eq("2024-01-15T14:30:00Z")
      expect(formatted_payload[:signal][:alert_timestamp]).to eq("2024-01-15T14:30:00Z")
    end

    context "when signal_type is missing" do
      let(:signal_data_without_type) { signal_data.except(:signal_type) }

      it "defaults to entry" do
        result = described_class.send(:format_signal_payload, signal_data_without_type)
        expect(result[:signal][:signal_type]).to eq("entry")
      end
    end

    context "when metadata is missing" do
      let(:signal_data_without_metadata) { signal_data.except(:metadata) }

      it "defaults to empty hash" do
        result = described_class.send(:format_signal_payload, signal_data_without_metadata)
        expect(result[:signal][:metadata]).to eq({})
      end
    end

    context "when strategy_data is missing" do
      let(:signal_data_without_strategy_data) { signal_data.except(:strategy_data) }

      it "defaults to empty hash" do
        result = described_class.send(:format_signal_payload, signal_data_without_strategy_data)
        expect(result[:signal][:strategy_data]).to eq({})
      end
    end
  end

  describe ".calculate_expiry" do
    context "for MultiTimeframeSignal strategy" do
      it "calculates expiry for 1m timeframe" do
        result = described_class.send(:calculate_expiry, "MultiTimeframeSignal", "1m")
        expect(result).to match(/T\d{2}:\d{2}:\d{2}Z/)

        # Should be 2 minutes from now
        parsed_time = Time.iso8601(result)
        expect(parsed_time).to be_within(5.seconds).of(2.minutes.from_now)
      end

      it "calculates expiry for 5m timeframe" do
        result = described_class.send(:calculate_expiry, "MultiTimeframeSignal", "5m")
        parsed_time = Time.iso8601(result)
        expect(parsed_time).to be_within(5.seconds).of(5.minutes.from_now)
      end

      it "calculates expiry for 15m timeframe" do
        result = described_class.send(:calculate_expiry, "MultiTimeframeSignal", "15m")
        parsed_time = Time.iso8601(result)
        expect(parsed_time).to be_within(5.seconds).of(15.minutes.from_now)
      end

      it "calculates expiry for 1h timeframe" do
        result = described_class.send(:calculate_expiry, "MultiTimeframeSignal", "1h")
        parsed_time = Time.iso8601(result)
        expect(parsed_time).to be_within(5.seconds).of(1.hour.from_now)
      end

      it "calculates default expiry for unknown timeframe" do
        result = described_class.send(:calculate_expiry, "MultiTimeframeSignal", "30m")
        parsed_time = Time.iso8601(result)
        expect(parsed_time).to be_within(5.seconds).of(30.minutes.from_now)
      end
    end

    context "for other strategies" do
      it "calculates 15 minute expiry" do
        result = described_class.send(:calculate_expiry, "OtherStrategy", "1h")
        parsed_time = Time.iso8601(result)
        expect(parsed_time).to be_within(5.seconds).of(15.minutes.from_now)
      end
    end

    context "when strategy_name is nil" do
      it "calculates 15 minute expiry" do
        result = described_class.send(:calculate_expiry, nil, "1h")
        parsed_time = Time.iso8601(result)
        expect(parsed_time).to be_within(5.seconds).of(15.minutes.from_now)
      end
    end
  end

  describe "integration with ActionCable" do
    it "uses ActionCable.server.broadcast" do
      expect(ActionCable).to receive(:server)
      described_class.broadcast(signal_data)
    end
  end

  describe "error handling" do
    context "when ActionCable broadcasting fails" do
      before do
        allow(ActionCable).to receive(:server).and_raise(StandardError.new("ActionCable unavailable"))
      end

      it "handles broadcast gracefully" do
        expect { described_class.broadcast(signal_data) }.not_to raise_error
      end

      it "logs the error" do
        expect(Rails.logger).to receive(:error).with("[SignalBroadcaster] Failed to broadcast signal: ActionCable unavailable")
        described_class.broadcast(signal_data)
      end
    end
  end

  describe "channel naming" do
    it "uses consistent channel names" do
      expect(mock_action_cable).to receive(:broadcast).with("signals", anything)
      expect(mock_action_cable).to receive(:broadcast).with("signals:BTC-USD", anything)
      expect(mock_action_cable).to receive(:broadcast).with("signals:strategy:MultiTimeframeSignal", anything)

      described_class.broadcast(signal_data)
    end
  end

  describe "payload structure" do
    it "maintains consistent payload structure" do
      payload = described_class.send(:format_signal_payload, signal_data)

      expect(payload).to have_key(:type)
      expect(payload).to have_key(:timestamp)
      expect(payload).to have_key(:signal)

      signal = payload[:signal]
      expect(signal).to have_key(:id)
      expect(signal).to have_key(:symbol)
      expect(signal).to have_key(:side)
      expect(signal).to have_key(:alert_status)
      expect(signal).to have_key(:expires_at)
    end
  end
end
