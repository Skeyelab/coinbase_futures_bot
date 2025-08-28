# frozen_string_literal: true

require "rails_helper"

RSpec.describe SignalAlert, type: :model do
  let(:valid_attributes) do
    {
      symbol: "BTC-USD",
      side: "long",
      signal_type: "entry",
      strategy_name: "MultiTimeframeSignal",
      confidence: 85.5,
      entry_price: 50_000.0,
      stop_loss: 49_000.0,
      take_profit: 52_000.0,
      quantity: 10,
      timeframe: "1h",
      alert_status: "active",
      alert_timestamp: Time.current.utc,
      expires_at: 1.hour.from_now.utc,
      metadata: {"test_key" => "test_value"},
      strategy_data: {"ema_short" => 49_900, "ema_long" => 49_800}
    }
  end

  describe "validations" do
    it "is valid with all required attributes" do
      signal = described_class.new(valid_attributes)
      expect(signal).to be_valid
    end

    describe "presence validations" do
      %i[symbol side signal_type strategy_name confidence].each do |attribute|
        it "requires #{attribute}" do
          signal = described_class.new(valid_attributes.except(attribute))
          expect(signal).not_to be_valid
          expect(signal.errors[attribute]).to include("can't be blank")
        end
      end
    end

    describe "symbol validation" do
      it "accepts valid symbols" do
        valid_symbols = %w[BTC-USD ETH-USD BTC-29AUG25-CDE ETH-29AUG25-CDE]
        valid_symbols.each do |symbol|
          signal = described_class.new(valid_attributes.merge(symbol: symbol))
          expect(signal).to be_valid
        end
      end

      it "rejects invalid symbols" do
        invalid_symbols = ["btc-usd", "BTC/USD", "BTC_USD", "btc usd", ""]
        invalid_symbols.each do |symbol|
          signal = described_class.new(valid_attributes.merge(symbol: symbol))
          expect(signal).not_to be_valid
          expect(signal.errors[:symbol]).to include("must be valid trading symbol")
        end
      end
    end

    describe "side validation" do
      it "accepts valid sides" do
        valid_sides = %w[long short buy sell]
        valid_sides.each do |side|
          signal = described_class.new(valid_attributes.merge(side: side))
          expect(signal).to be_valid
        end
      end

      it "rejects invalid sides" do
        signal = described_class.new(valid_attributes.merge(side: "invalid"))
        expect(signal).not_to be_valid
        expect(signal.errors[:side]).to include("is not included in the list")
      end
    end

    describe "signal_type validation" do
      it "accepts valid signal types" do
        valid_types = %w[entry exit stop_loss take_profit]
        valid_types.each do |type|
          signal = described_class.new(valid_attributes.merge(signal_type: type))
          expect(signal).to be_valid
        end
      end

      it "rejects invalid signal types" do
        signal = described_class.new(valid_attributes.merge(signal_type: "invalid"))
        expect(signal).not_to be_valid
        expect(signal.errors[:signal_type]).to include("is not included in the list")
      end
    end

    describe "alert_status validation" do
      it "accepts valid statuses" do
        valid_statuses = %w[active triggered expired cancelled]
        valid_statuses.each do |status|
          signal = described_class.new(valid_attributes.merge(alert_status: status))
          expect(signal).to be_valid
        end
      end

      it "rejects invalid statuses" do
        signal = described_class.new(valid_attributes.merge(alert_status: "invalid"))
        expect(signal).not_to be_valid
        expect(signal.errors[:alert_status]).to include("is not included in the list")
      end

      it "allows nil status" do
        signal = described_class.new(valid_attributes.merge(alert_status: nil))
        expect(signal).to be_valid
      end
    end

    describe "confidence validation" do
      it "accepts values between 0 and 100" do
        [0.1, 50.0, 99.9, 100.0].each do |confidence|
          signal = described_class.new(valid_attributes.merge(confidence: confidence))
          expect(signal).to be_valid
        end
      end

      it "rejects values <= 0" do
        signal = described_class.new(valid_attributes.merge(confidence: 0))
        expect(signal).not_to be_valid
        expect(signal.errors[:confidence]).to include("must be greater than 0")
      end

      it "rejects values > 100" do
        signal = described_class.new(valid_attributes.merge(confidence: 100.1))
        expect(signal).not_to be_valid
        expect(signal.errors[:confidence]).to include("must be less than or equal to 100")
      end
    end

    describe "price validations" do
      %i[entry_price stop_loss take_profit].each do |attribute|
        it "accepts positive #{attribute}" do
          signal = described_class.new(valid_attributes.merge(attribute => 50_000.0))
          expect(signal).to be_valid
        end

        it "rejects zero #{attribute}" do
          signal = described_class.new(valid_attributes.merge(attribute => 0))
          expect(signal).not_to be_valid
          expect(signal.errors[attribute]).to include("must be greater than 0")
        end

        it "rejects negative #{attribute}" do
          signal = described_class.new(valid_attributes.merge(attribute => -100))
          expect(signal).not_to be_valid
          expect(signal.errors[attribute]).to include("must be greater than 0")
        end

        it "allows nil #{attribute}" do
          signal = described_class.new(valid_attributes.merge(attribute => nil))
          expect(signal).to be_valid
        end
      end
    end

    describe "quantity validation" do
      it "accepts positive integers" do
        signal = described_class.new(valid_attributes.merge(quantity: 10))
        expect(signal).to be_valid
      end

      it "rejects zero quantity" do
        signal = described_class.new(valid_attributes.merge(quantity: 0))
        expect(signal).not_to be_valid
        expect(signal.errors[:quantity]).to include("must be greater than 0")
      end

      it "rejects negative quantity" do
        signal = described_class.new(valid_attributes.merge(quantity: -5))
        expect(signal).not_to be_valid
        expect(signal.errors[:quantity]).to include("must be greater than 0")
      end

      it "rejects non-integer quantity" do
        signal = described_class.new(valid_attributes.merge(quantity: 5.5))
        expect(signal).not_to be_valid
        expect(signal.errors[:quantity]).to include("must be an integer")
      end

      it "allows nil quantity" do
        signal = described_class.new(valid_attributes.merge(quantity: nil))
        expect(signal).to be_valid
      end
    end

    describe "timeframe validation" do
      it "accepts valid timeframes" do
        valid_timeframes = %w[1m 5m 15m 1h 6h 1d]
        valid_timeframes.each do |timeframe|
          signal = described_class.new(valid_attributes.merge(timeframe: timeframe))
          expect(signal).to be_valid
        end
      end

      it "rejects invalid timeframes" do
        signal = described_class.new(valid_attributes.merge(timeframe: "invalid"))
        expect(signal).not_to be_valid
        expect(signal.errors[:timeframe]).to include("is not included in the list")
      end

      it "allows nil timeframe" do
        signal = described_class.new(valid_attributes.merge(timeframe: nil))
        expect(signal).to be_valid
      end
    end
  end

  describe "before_create callback" do
    describe "#set_defaults" do
      it "sets default alert_status to active" do
        signal = described_class.create!(valid_attributes.except(:alert_status))
        expect(signal.alert_status).to eq("active")
      end

      it "sets default alert_timestamp to current time" do
        signal = described_class.create!(valid_attributes.except(:alert_timestamp))
        expect(signal.alert_timestamp).to be_within(1.second).of(Time.current.utc)
      end

      it "sets default expires_at based on strategy and timeframe" do
        signal = described_class.create!(valid_attributes.except(:expires_at))
        expect(signal.expires_at).to be_within(1.second).of(1.hour.from_now.utc)
      end
    end
  end

  describe "scopes" do
    let!(:active_signal) { described_class.create!(valid_attributes.merge(alert_status: "active")) }
    let!(:triggered_signal) { described_class.create!(valid_attributes.merge(alert_status: "triggered")) }
    let!(:expired_signal) { described_class.create!(valid_attributes.merge(alert_status: "expired")) }
    let!(:cancelled_signal) { described_class.create!(valid_attributes.merge(alert_status: "cancelled")) }
    let!(:btc_signal) { described_class.create!(valid_attributes.merge(symbol: "BTC-USD")) }
    let!(:eth_signal) { described_class.create!(valid_attributes.merge(symbol: "ETH-USD")) }
    let!(:long_signal) { described_class.create!(valid_attributes.merge(side: "long")) }
    let!(:short_signal) { described_class.create!(valid_attributes.merge(side: "short")) }
    let!(:high_confidence_signal) { described_class.create!(valid_attributes.merge(confidence: 85)) }
    let!(:low_confidence_signal) { described_class.create!(valid_attributes.merge(confidence: 60)) }
    let!(:entry_signal) { described_class.create!(valid_attributes.merge(signal_type: "entry")) }
    let!(:exit_signal) { described_class.create!(valid_attributes.merge(signal_type: "exit")) }

    describe ".active" do
      it "returns only active signals" do
        expect(described_class.active).to include(active_signal)
        expect(described_class.active).not_to include(triggered_signal, expired_signal, cancelled_signal)
      end
    end

    describe ".triggered" do
      it "returns only triggered signals" do
        expect(described_class.triggered).to include(triggered_signal)
        expect(described_class.triggered).not_to include(active_signal, expired_signal, cancelled_signal)
      end
    end

    describe ".expired" do
      it "returns only expired signals" do
        expect(described_class.expired).to include(expired_signal)
        expect(described_class.expired).not_to include(active_signal, triggered_signal, cancelled_signal)
      end
    end

    describe ".cancelled" do
      it "returns only cancelled signals" do
        expect(described_class.cancelled).to include(cancelled_signal)
        expect(described_class.cancelled).not_to include(active_signal, triggered_signal, expired_signal)
      end
    end

    describe ".for_symbol" do
      it "returns signals for specific symbol" do
        expect(described_class.for_symbol("BTC-USD")).to include(btc_signal)
        expect(described_class.for_symbol("BTC-USD")).not_to include(eth_signal)
      end
    end

    describe ".by_strategy" do
      it "returns signals for specific strategy" do
        expect(described_class.by_strategy("MultiTimeframeSignal")).to include(active_signal)
      end
    end

    describe ".by_side" do
      it "returns signals for specific side" do
        expect(described_class.by_side("long")).to include(long_signal)
        expect(described_class.by_side("long")).not_to include(short_signal)
      end
    end

    describe ".high_confidence" do
      it "returns signals above threshold (default 70)" do
        expect(described_class.high_confidence).to include(high_confidence_signal)
        expect(described_class.high_confidence).not_to include(low_confidence_signal)
      end

      it "returns signals above custom threshold" do
        expect(described_class.high_confidence(80)).to include(high_confidence_signal)
        expect(described_class.high_confidence(80)).not_to include(low_confidence_signal)
      end
    end

    describe ".recent" do
      it "returns signals from last 24 hours by default" do
        expect(described_class.recent).to include(active_signal)
      end

      it "returns signals from custom hours ago" do
        expect(described_class.recent(1)).to include(active_signal)
      end
    end

    describe ".expiring_soon" do
      let!(:expiring_signal) { described_class.create!(valid_attributes.merge(expires_at: 30.minutes.from_now)) }
      let!(:not_expiring_signal) { described_class.create!(valid_attributes.merge(expires_at: 2.hours.from_now)) }

      it "returns signals expiring within default 60 minutes" do
        expect(described_class.expiring_soon).to include(expiring_signal)
        expect(described_class.expiring_soon).not_to include(not_expiring_signal)
      end

      it "returns signals expiring within custom minutes" do
        expect(described_class.expiring_soon(45)).to include(expiring_signal)
        expect(described_class.expiring_soon(15)).not_to include(expiring_signal)
      end
    end

    describe ".entry_signals" do
      it "returns only entry signals" do
        expect(described_class.entry_signals).to include(entry_signal)
        expect(described_class.entry_signals).not_to include(exit_signal)
      end
    end

    describe ".exit_signals" do
      it "returns exit signals (exit, stop_loss, take_profit)" do
        expect(described_class.exit_signals).to include(exit_signal)
        expect(described_class.exit_signals).not_to include(entry_signal)
      end
    end
  end

  describe "class methods" do
    describe ".create_entry_signal!" do
      let(:entry_signal_attrs) do
        {
          symbol: "BTC-USD",
          side: "long",
          strategy_name: "MultiTimeframeSignal",
          confidence: 85.0,
          entry_price: 50_000.0,
          stop_loss: 49_000.0,
          take_profit: 52_000.0,
          quantity: 10,
          timeframe: "1h",
          metadata: {"test" => "metadata"},
          strategy_data: {"ema_short" => 49_900, "ema_long" => 49_800}
        }
      end

      it "creates entry signal with correct attributes" do
        signal = described_class.create_entry_signal!(
          symbol: "BTC-USD",
          side: "long",
          strategy_name: "MultiTimeframeSignal",
          confidence: 85.0,
          entry_price: 50_000.0,
          stop_loss: 49_000.0,
          take_profit: 52_000.0,
          quantity: 10,
          timeframe: "1h",
          metadata: {"test" => "metadata"},
          strategy_data: {"ema_short" => 49_900, "ema_long" => 49_800}
        )

        expect(signal.symbol).to eq("BTC-USD")
        expect(signal.side).to eq("long")
        expect(signal.signal_type).to eq("entry")
        expect(signal.strategy_name).to eq("MultiTimeframeSignal")
        expect(signal.confidence).to eq(85.0)
        expect(signal.entry_price).to eq(50_000.0)
        expect(signal.stop_loss).to eq(49_000.0)
        expect(signal.take_profit).to eq(52_000.0)
        expect(signal.quantity).to eq(10)
        expect(signal.timeframe).to eq("1h")
        expect(signal.alert_status).to eq("active")
        expect(signal.metadata).to eq({"test" => "metadata"})
        expect(signal.strategy_data).to eq({"ema_short" => 49_900, "ema_long" => 49_800})
      end

      it "sets alert_timestamp to current time" do
        signal = described_class.create_entry_signal!(
          symbol: "BTC-USD",
          side: "long",
          strategy_name: "MultiTimeframeSignal",
          confidence: 85.0,
          entry_price: 50_000.0,
          stop_loss: 49_000.0,
          take_profit: 52_000.0,
          quantity: 10,
          timeframe: "1h"
        )
        expect(signal.alert_timestamp).to be_within(1.second).of(Time.current.utc)
      end

      it "sets appropriate expiry based on timeframe" do
        signal = described_class.create_entry_signal!(
          symbol: "BTC-USD",
          side: "long",
          strategy_name: "MultiTimeframeSignal",
          confidence: 85.0,
          entry_price: 50_000.0,
          stop_loss: 49_000.0,
          take_profit: 52_000.0,
          quantity: 10,
          timeframe: "5m"
        )
        expect(signal.expires_at).to be_within(1.second).of(5.minutes.from_now.utc)
      end

      it "raises error on invalid attributes" do
        attrs = entry_signal_attrs.except(:symbol)
        expect do
          described_class.create_entry_signal!(**attrs)
        end.to raise_error(ArgumentError)
      end
    end

    describe ".create_exit_signal!" do
      let(:exit_signal_attrs) do
        {
          symbol: "BTC-USD",
          signal_type: "take_profit",
          strategy_name: "MultiTimeframeSignal",
          confidence: 90.0,
          entry_price: 52_000.0,
          quantity: 5,
          metadata: {"pnl" => 2000},
          strategy_data: {"exit_reason" => "take_profit_hit"}
        }
      end

      it "creates exit signal with correct attributes" do
        signal = described_class.create_exit_signal!(
          symbol: "BTC-USD",
          signal_type: "take_profit",
          strategy_name: "MultiTimeframeSignal",
          confidence: 90.0,
          entry_price: 52_000.0,
          quantity: 5,
          metadata: {"pnl" => 2000},
          strategy_data: {"exit_reason" => "take_profit_hit"}
        )

        expect(signal.symbol).to eq("BTC-USD")
        expect(signal.signal_type).to eq("take_profit")
        expect(signal.strategy_name).to eq("MultiTimeframeSignal")
        expect(signal.confidence).to eq(90.0)
        expect(signal.entry_price).to eq(52_000.0)
        expect(signal.quantity).to eq(5)
        expect(signal.alert_status).to eq("active")
        expect(signal.metadata).to eq({"pnl" => 2000})
        expect(signal.strategy_data).to eq({"exit_reason" => "take_profit_hit"})
      end

      it "sets side based on signal type" do
        signal = described_class.create_exit_signal!(
          symbol: "BTC-USD",
          signal_type: "stop_loss",
          strategy_name: "MultiTimeframeSignal",
          confidence: 90.0,
          entry_price: 52_000.0,
          quantity: 5
        )
        expect(signal.side).to eq("unknown") # As defined in determine_exit_side
      end

      it "sets short expiry for exit signals" do
        signal = described_class.create_exit_signal!(
          symbol: "BTC-USD",
          signal_type: "take_profit",
          strategy_name: "MultiTimeframeSignal",
          confidence: 90.0,
          entry_price: 52_000.0,
          quantity: 5
        )
        expect(signal.expires_at).to be_within(1.second).of(5.minutes.from_now.utc)
      end

      it "raises error on invalid attributes" do
        attrs = exit_signal_attrs.except(:symbol)
        expect do
          described_class.create_exit_signal!(**attrs)
        end.to raise_error(ArgumentError)
      end
    end

    describe ".calculate_expiry" do
      it "calculates expiry for MultiTimeframeSignal based on timeframe" do
        expect(described_class.send(:calculate_expiry, "MultiTimeframeSignal",
          "1m")).to be_within(1.second).of(2.minutes.from_now.utc)
        expect(described_class.send(:calculate_expiry, "MultiTimeframeSignal",
          "5m")).to be_within(1.second).of(5.minutes.from_now.utc)
        expect(described_class.send(:calculate_expiry, "MultiTimeframeSignal",
          "15m")).to be_within(1.second).of(15.minutes.from_now.utc)
        expect(described_class.send(:calculate_expiry, "MultiTimeframeSignal",
          "1h")).to be_within(1.second).of(1.hour.from_now.utc)
        expect(described_class.send(:calculate_expiry, "MultiTimeframeSignal",
          "invalid")).to be_within(1.second).of(30.minutes.from_now.utc)
      end

      it "calculates default expiry for other strategies" do
        expect(described_class.send(:calculate_expiry, "OtherStrategy",
          "1m")).to be_within(1.second).of(15.minutes.from_now.utc)
      end
    end

    describe ".determine_exit_side" do
      it "returns unknown for stop_loss and take_profit" do
        expect(described_class.send(:determine_exit_side, "stop_loss")).to eq("unknown")
        expect(described_class.send(:determine_exit_side, "take_profit")).to eq("unknown")
      end

      it "returns unknown for other signal types" do
        expect(described_class.send(:determine_exit_side, "entry")).to eq("unknown")
        expect(described_class.send(:determine_exit_side, "exit")).to eq("unknown")
      end
    end
  end

  describe "instance methods" do
    let(:signal) { described_class.create!(valid_attributes) }

    describe "#triggered?" do
      it "returns true when status is triggered" do
        signal.update!(alert_status: "triggered")
        expect(signal.triggered?).to be true
      end

      it "returns false when status is not triggered" do
        expect(signal.triggered?).to be false
      end
    end

    describe "#active?" do
      it "returns true when status is active" do
        expect(signal.active?).to be true
      end

      it "returns false when status is not active" do
        signal.update!(alert_status: "triggered")
        expect(signal.active?).to be false
      end
    end

    describe "#expired?" do
      it "returns true when status is expired" do
        signal.update!(alert_status: "expired")
        expect(signal.expired?).to be true
      end

      it "returns true when expires_at is in the past" do
        signal.update!(expires_at: 1.hour.ago)
        expect(signal.expired?).to be true
      end

      it "returns false when expires_at is in the future" do
        expect(signal.expired?).to be false
      end
    end

    describe "#long?" do
      it "returns true for long positions" do
        signal.update!(side: "long")
        expect(signal.long?).to be true
      end

      it "returns true for buy positions" do
        signal.update!(side: "buy")
        expect(signal.long?).to be true
      end

      it "returns false for short/sell positions" do
        signal.update!(side: "short")
        expect(signal.long?).to be false
      end
    end

    describe "#short?" do
      it "returns true for short positions" do
        signal.update!(side: "short")
        expect(signal.short?).to be true
      end

      it "returns true for sell positions" do
        signal.update!(side: "sell")
        expect(signal.short?).to be true
      end

      it "returns false for long/buy positions" do
        signal.update!(side: "long")
        expect(signal.short?).to be false
      end
    end

    describe "#entry_signal?" do
      it "returns true for entry signals" do
        signal.update!(signal_type: "entry")
        expect(signal.entry_signal?).to be true
      end

      it "returns false for exit signals" do
        signal.update!(signal_type: "exit")
        expect(signal.entry_signal?).to be false
      end
    end

    describe "#exit_signal?" do
      it "returns true for exit signals" do
        %w[exit stop_loss take_profit].each do |type|
          signal.update!(signal_type: type)
          expect(signal.exit_signal?).to be true
        end
      end

      it "returns false for entry signals" do
        signal.update!(signal_type: "entry")
        expect(signal.exit_signal?).to be false
      end
    end

    describe "#trigger!" do
      it "updates status to triggered and sets triggered_at" do
        signal.trigger!
        expect(signal.alert_status).to eq("triggered")
        expect(signal.triggered_at).to be_within(1.second).of(Time.current.utc)
      end
    end

    describe "#cancel!" do
      it "updates status to cancelled" do
        signal.cancel!
        expect(signal.alert_status).to eq("cancelled")
      end
    end

    describe "#expire!" do
      it "updates status to expired" do
        signal.expire!
        expect(signal.alert_status).to eq("expired")
      end
    end

    describe "#to_api_response" do
      it "returns formatted API response" do
        response = signal.to_api_response

        expect(response).to include(
          id: signal.id,
          symbol: "BTC-USD",
          side: "long",
          signal_type: "entry",
          strategy_name: "MultiTimeframeSignal",
          confidence: 85.5,
          entry_price: 50_000.0,
          stop_loss: 49_000.0,
          take_profit: 52_000.0,
          quantity: 10,
          timeframe: "1h",
          alert_status: "active"
        )

        expect(response[:alert_timestamp]).to be_a(String)
        expect(response[:expires_at]).to be_a(String)
        expect(response[:created_at]).to be_a(String)
        expect(response[:updated_at]).to be_a(String)
        expect(response[:metadata]).to eq({"test_key" => "test_value"})
      end

      it "handles nil values in API response" do
        signal.update!(
          entry_price: nil,
          stop_loss: nil,
          take_profit: nil,
          expires_at: nil
        )
        response = signal.to_api_response

        expect(response[:entry_price]).to be_nil
        expect(response[:stop_loss]).to be_nil
        expect(response[:take_profit]).to be_nil
        expect(response[:expires_at]).to be_nil
      end
    end
  end
end
