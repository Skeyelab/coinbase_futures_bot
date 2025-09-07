# frozen_string_literal: true

require "rails_helper"

RSpec.describe GenerateSignalsJob, type: :job do
  let(:job) { described_class.new }
  let(:mock_strategy) { instance_double(Strategy::MultiTimeframeSignal) }
  let!(:trading_pair) { create(:trading_pair, enabled: true, product_id: "BTC-29DEC24-CDE") }
  let(:mock_signal) do
    {
      side: "long",
      price: 50_000.0,
      quantity: 1,
      tp: 52_000.0,
      sl: 49_000.0,
      confidence: 80
    }
  end

  before do
    allow(Strategy::MultiTimeframeSignal).to receive(:new).and_return(mock_strategy)
    allow(SlackNotificationService).to receive(:signal_generated)
    # Allow puts to be called without mocking it
    allow(job).to receive(:puts).and_call_original
  end

  describe "#perform" do
    context "with default equity" do
      before do
        allow(mock_strategy).to receive(:signal).and_return(mock_signal)
        # Mock the default_equity_usd method for this context
        allow(job).to receive(:default_equity_usd).and_return(10_000.0)
      end

      it "initializes strategy with correct parameters" do
        expect(Strategy::MultiTimeframeSignal).to receive(:new).with(
          ema_1h_short: 21,
          ema_1h_long: 50,
          ema_15m: 21,
          min_1h_candles: 60,
          min_15m_candles: 80
        )

        job.perform
      end

      it "processes all enabled trading pairs" do
        expect(mock_strategy).to receive(:signal).with(
          {symbol: trading_pair.product_id, equity_usd: 10_000.0}
        )

        job.perform
      end

      it "logs analysis start for each pair" do
        expect(job).to receive(:puts).with("Analyzing #{trading_pair.product_id}...")

        job.perform
      end
    end

    context "with custom equity" do
      before do
        allow(mock_strategy).to receive(:signal).and_return(mock_signal)
      end

      it "uses provided equity amount" do
        expect(mock_strategy).to receive(:signal).with(
          {symbol: trading_pair.product_id, equity_usd: 25_000.0}
        )

        job.perform(equity_usd: 25_000.0)
      end
    end

    context "when strategy returns a signal" do
      before do
        allow(mock_strategy).to receive(:signal).and_return(mock_signal)
      end

      it "logs the signal details" do
        expect(job).to receive(:puts).with(
          "[Signal] #{trading_pair.product_id} side=long price=50000.0 qty=1 tp=52000.0 sl=49000.0 conf=80%"
        )

        job.perform
      end

      it "sends Slack notification" do
        expect(SlackNotificationService).to receive(:signal_generated).with(
          {
            symbol: trading_pair.product_id,
            side: "long",
            price: 50_000.0,
            quantity: 1,
            tp: 52_000.0,
            sl: 49_000.0,
            confidence: 80
          }
        )

        job.perform
      end
    end

    context "when strategy returns no signal" do
      before do
        allow(mock_strategy).to receive(:signal).and_return(nil)
      end

      it "logs no-entry message" do
        expect(job).to receive(:puts).with("[Signal] #{trading_pair.product_id} no-entry")

        job.perform
      end

      it "does not send Slack notification" do
        expect(SlackNotificationService).not_to receive(:signal_generated)

        job.perform
      end
    end

    context "when no enabled trading pairs exist" do
      before do
        TradingPair.update_all(enabled: false)
      end

      it "still initializes strategy but processes no pairs" do
        expect(Strategy::MultiTimeframeSignal).to receive(:new)
        expect(mock_strategy).not_to receive(:signal)

        job.perform
      end
    end

    context "when multiple trading pairs exist" do
      let!(:trading_pair2) { create(:trading_pair, enabled: true, product_id: "ETH-29DEC24-CDE") }

      before do
        allow(mock_strategy).to receive(:signal).and_return(mock_signal)
        # Mock the default_equity_usd method for this context
        allow(job).to receive(:default_equity_usd).and_return(10_000.0)
      end

      it "processes all enabled pairs" do
        expect(mock_strategy).to receive(:signal).twice

        job.perform
      end
    end
  end

  describe "#default_equity_usd" do
    context "when SIGNAL_EQUITY_USD environment variable is set" do
      before do
        allow(ENV).to receive(:[]).with("SIGNAL_EQUITY_USD").and_return("20000")
      end

      it "returns the environment variable value as float" do
        expect(job.send(:default_equity_usd)).to eq(20_000.0)
      end
    end

    context "when SIGNAL_EQUITY_USD environment variable is not set" do
      before do
        allow(ENV).to receive(:[]).with("SIGNAL_EQUITY_USD").and_return(nil)
      end

      it "returns default value of 10,000" do
        expect(job.send(:default_equity_usd)).to eq(10_000.0)
      end
    end

    context "when SIGNAL_EQUITY_USD is an invalid number" do
      before do
        allow(ENV).to receive(:[]).with("SIGNAL_EQUITY_USD").and_return("invalid")
      end

      it "returns 0.0" do
        expect(job.send(:default_equity_usd)).to eq(0.0)
      end
    end
  end

  describe "job configuration" do
    it "uses the default queue" do
      expect(described_class.queue_name).to eq("default")
    end

    it "inherits from ApplicationJob" do
      expect(described_class.superclass).to eq(ApplicationJob)
    end
  end

  describe "error handling" do
    context "when strategy initialization fails" do
      before do
        allow(Strategy::MultiTimeframeSignal).to receive(:new).and_raise(StandardError.new("Strategy init failed"))
        allow(mock_strategy).to receive(:signal).and_return(nil)
        # Mock the default_equity_usd method for this context
        allow(job).to receive(:default_equity_usd).and_return(10_000.0)
      end

      it "raises the error" do
        expect { job.perform }.to raise_error(StandardError, "Strategy init failed")
      end
    end

    context "when signal generation fails" do
      before do
        allow(mock_strategy).to receive(:signal).and_raise(StandardError.new("Signal generation failed"))
        # Mock the default_equity_usd method for this context
        allow(job).to receive(:default_equity_usd).and_return(10_000.0)
      end

      it "raises the error" do
        expect { job.perform }.to raise_error(StandardError, "Signal generation failed")
      end
    end

    context "when Slack notification fails" do
      before do
        allow(mock_strategy).to receive(:signal).and_return(mock_signal)
        allow(SlackNotificationService).to receive(:signal_generated).and_raise(StandardError.new("Slack error"))
        # Mock the default_equity_usd method for this context
        allow(job).to receive(:default_equity_usd).and_return(10_000.0)
      end

      it "raises the error" do
        expect { job.perform }.to raise_error(StandardError, "Slack error")
      end
    end
  end

  describe "integration with ActiveJob" do
    it "can be enqueued" do
      expect do
        described_class.perform_later
      end.not_to raise_error
    end

    it "can be enqueued with custom equity" do
      expect do
        described_class.perform_later(equity_usd: 50_000)
      end.not_to raise_error
    end
  end
end
