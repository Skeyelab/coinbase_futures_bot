# frozen_string_literal: true

require "rails_helper"

RSpec.describe GenerateSignalsJob, type: :job do
  let(:job) { described_class.new }
  let(:mock_strategy) { instance_double(Strategy::MultiTimeframeSignal) }
  let!(:contract) { create(:contract, enabled: true, product_id: "BTC-29DEC24-CDE") }
  let(:mock_signal) do
    {
      side: :long,
      price: 50_000.0,
      quantity: 1,
      tp: 52_000.0,
      sl: 49_000.0,
      confidence: 80
    }
  end

  before do
    # The notification throttle is cache-backed; a stale key from a previous
    # example would silently swallow expected notifications.
    Rails.cache.clear
    allow(Strategy::MultiTimeframeSignal).to receive(:new).and_return(mock_strategy)
    allow(SlackNotificationService).to receive(:signal_generated)
    # Allow puts to be called without mocking it
    allow(job).to receive(:puts).and_call_original
    # Default: paper trading on so executor not called unless test overrides
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("PAPER_TRADING_MODE").and_return("true")
  end

  describe "#perform" do
    context "with default equity" do
      before do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:fetch).with("SIGNAL_EQUITY_USD", anything).and_return("10000")
        allow(mock_strategy).to receive(:signal).and_return(mock_signal)
        # Mock the default_equity_usd method for this context
        allow(job).to receive(:default_equity_usd).and_return(10_000.0)
      end

      it "initializes strategy with correct parameters" do
        expect(Strategy::MultiTimeframeSignal).to receive(:new).with(
          hash_including(ema_1h_short: 21, ema_1h_long: 50, ema_15m: 21,
            min_1h_candles: 60, min_15m_candles: 80)
        )

        job.perform
      end

      it "processes all enabled trading pairs" do
        expect(mock_strategy).to receive(:signal).with(
          {symbol: contract.product_id, equity_usd: 10_000.0}
        )

        job.perform
      end

      it "logs analysis start for each pair" do
        expect(job).to receive(:puts).with("Analyzing #{contract.product_id}...")

        job.perform
      end
    end

    context "with custom equity" do
      before do
        allow(mock_strategy).to receive(:signal).and_return(mock_signal)
      end

      it "uses provided equity amount" do
        expect(mock_strategy).to receive(:signal).with(
          {symbol: contract.product_id, equity_usd: 25_000.0}
        )

        job.perform(equity_usd: 25_000.0)
      end
    end

    context "when strategy returns a signal and live trading is enabled" do
      let(:mock_executor) { instance_double(Execution::FuturesExecutor) }

      before do
        allow(mock_strategy).to receive(:signal).and_return(mock_signal)
        allow(Execution::FuturesExecutor).to receive(:new).and_return(mock_executor)
        allow(mock_executor).to receive(:consider_entry)
        allow(ENV).to receive(:[]).with("PAPER_TRADING_MODE").and_return("false")
        DryRun.disable!(confirm: "LIVE", reason: "spec setup")
      end

      it "calls executor with signal price and product_id" do
        expect(mock_executor).to receive(:consider_entry).with(
          spot_price: mock_signal[:price],
          futures_product_id: contract.product_id
        )
        job.perform
      end
    end

    context "when strategy returns a signal and paper trading is enabled" do
      let(:mock_executor) { instance_double(Execution::FuturesExecutor) }

      before do
        allow(mock_strategy).to receive(:signal).and_return(mock_signal)
        # PAPER_TRADING_MODE=true already set in outer before block
      end

      it "does not call executor" do
        expect(mock_executor).not_to receive(:consider_entry)
        job.perform
      end
    end

    context "when strategy returns a signal" do
      before do
        allow(mock_strategy).to receive(:signal).and_return(mock_signal)
      end

      it "logs the signal details" do
        expect(job).to receive(:puts).with(
          "[Signal] #{contract.product_id} side=long price=50000.0 qty=1 tp=52000.0 sl=49000.0 conf=80%"
        )

        job.perform
      end

      it "sends Slack notification" do
        expect(SlackNotificationService).to receive(:signal_generated).with(
          {
            symbol: contract.product_id,
            side: :long,
            price: 50_000.0,
            quantity: 1,
            tp: 52_000.0,
            sl: 49_000.0,
            confidence: 80
          }
        )

        job.perform
      end

      # 2026-07-28 storm regression: the job runs every 15 minutes and used to
      # re-announce the same still-valid signal on every run (and on every
      # GoodJob retry — see the halted context below). One announcement per
      # symbol+side per throttle window is the contract.
      it "does not re-announce the same symbol+side within the throttle window" do
        Rails.cache.clear
        expect(SlackNotificationService).to receive(:signal_generated).once

        job.perform
        described_class.new.perform
      end
    end

    # 2026-07-28 storm regression: a signal + an active halt turned one cron
    # tick into ~3 retries/second (GoodJob retries unhandled errors with no
    # backoff), each posting to Slack before crashing on HaltedError. A halt is
    # a state — the job must skip execution and complete, not crash and retry.
    context "when trading is halted and live trading is enabled" do
      let(:mock_executor) { instance_double(Execution::FuturesExecutor) }

      before do
        Rails.cache.clear
        allow(mock_strategy).to receive(:signal).and_return(mock_signal)
        allow(Execution::FuturesExecutor).to receive(:new).and_return(mock_executor)
        allow(mock_executor).to receive(:consider_entry)
          .and_raise(TradingHalt::HaltedError, "Trading is halted (daily realized loss $12.60 breached cap $10.00)")
        allow(ENV).to receive(:[]).with("PAPER_TRADING_MODE").and_return("false")
      end

      it "completes without raising" do
        expect { job.perform }.not_to raise_error
      end

      it "still announces the signal once" do
        expect(SlackNotificationService).to receive(:signal_generated).once
        job.perform
      end

      it "discards rather than retries if a HaltedError escapes anyway" do
        expect(described_class.rescue_handlers.map(&:first)).to include("TradingHalt::HaltedError")
      end
    end

    context "when the durable dry-run state is active but PAPER_TRADING_MODE is unset" do
      let(:mock_executor) { instance_double(Execution::FuturesExecutor) }

      before do
        Rails.cache.clear
        allow(mock_strategy).to receive(:signal).and_return(mock_signal)
        allow(Execution::FuturesExecutor).to receive(:new).and_return(mock_executor)
        allow(ENV).to receive(:[]).with("PAPER_TRADING_MODE").and_return(nil)
        allow(DryRun).to receive(:active?).and_return(true)
      end

      it "does not walk the live execution path" do
        expect(mock_executor).not_to receive(:consider_entry)
        job.perform
      end
    end

    context "when strategy returns no signal" do
      before do
        allow(mock_strategy).to receive(:signal).and_return(nil)
      end

      it "logs no-entry message" do
        expect(job).to receive(:puts).with("[Signal] #{contract.product_id} no-entry")

        job.perform
      end

      it "does not send Slack notification" do
        expect(SlackNotificationService).not_to receive(:signal_generated)

        job.perform
      end
    end

    context "when no enabled trading pairs exist" do
      before do
        Contract.update_all(enabled: false)
      end

      # Strategy resolution is per-pair since #303 (a symbol's entry in
      # strategy_selection.yml picks its class), so with no pairs there is
      # nothing to resolve and no strategy is built at all.
      it "builds no strategy and consults none" do
        expect(Strategy::MultiTimeframeSignal).not_to receive(:new)
        expect(mock_strategy).not_to receive(:signal)

        job.perform
      end
    end

    context "when multiple trading pairs exist" do
      let!(:contract2) { create(:contract, enabled: true, product_id: "ETH-29DEC24-CDE") }

      before do
        allow(mock_strategy).to receive(:signal).and_return(mock_signal)
        # Mock the default_equity_usd method for this context
        allow(job).to receive(:default_equity_usd).and_return(10_000.0)
      end

      it "processes all enabled pairs" do
        enabled_count = Contract.enabled.count
        expect(mock_strategy).to receive(:signal).exactly(enabled_count).times

        job.perform
      end
    end
  end

  describe "#default_equity_usd" do
    context "when SIGNAL_EQUITY_USD environment variable is set" do
      before do
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:fetch).with("SIGNAL_EQUITY_USD", anything).and_return("20000")
      end

      it "returns the environment variable value as float" do
        expect(job.send(:default_equity_usd)).to eq(20_000.0)
      end
    end

    context "when SIGNAL_EQUITY_USD environment variable is not set" do
      before do
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:fetch).with("SIGNAL_EQUITY_USD", anything).and_return("10000")
      end

      it "returns default value of 10,000" do
        expect(job.send(:default_equity_usd)).to eq(10_000.0)
      end
    end

    context "when SIGNAL_EQUITY_USD is an invalid number" do
      before do
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:fetch).with("SIGNAL_EQUITY_USD", anything).and_return("invalid")
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
    before do
      # Mock Contract.enabled to return only our test trading pair
      allow(Contract).to receive(:enabled) do
        double.tap do |relation|
          allow(relation).to receive(:find_each) do |&block|
            block.call(contract)
          end
        end
      end
    end

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

  # ========== COMPREHENSIVE SIGNAL GENERATION TESTING ==========
  # These tests cover the high-priority scenarios from Linear issue FUT-49

  # Strategy behaviour is not tested here, and cannot be: every example in this
  # file replaces Strategy::MultiTimeframeSignal with a double. Which market
  # conditions produce a long, a short, or no entry is owned by
  # spec/services/strategy/multi_timeframe_signal_spec.rb, which drives the real
  # strategy against real candles.
  #
  # This block was three contexts named "with bullish/bearish/sideways market
  # conditions", each inserting 80+ candles and a sentiment row that the stubbed
  # strategy never read. Deleting every one of those rows left the examples
  # green — they asserted nothing about market conditions, only that the job
  # echoed values the test itself had stubbed.
  #
  # What the job does own is the fan-out below: one signal reaches three
  # destinations in three different shapes, and the rounding difference between
  # them is real logic that nothing else covers.
  describe "signal fan-out" do
    # Deliberately un-round. mock_signal above is already at 2dp, so it cannot
    # tell a rounded field apart from an unrounded one.
    let(:unrounded_signal) do
      {
        side: :long,
        price: 50_800.126,
        quantity: 2,
        tp: 51_000.987,
        sl: 50_600.454,
        confidence: 85.5
      }
    end

    before { allow(mock_strategy).to receive(:signal).and_return(unrounded_signal) }

    it "rounds price, tp and sl to 2dp in the operator log line" do
      expect(job).to receive(:puts).with(
        "[Signal] #{contract.product_id} side=long price=50800.13 qty=2 " \
        "tp=51000.99 sl=50600.45 conf=85.5%"
      )

      job.perform(equity_usd: 25_000.0)
    end

    # The log rounds for readability. Slack must not: an operator reconciling a
    # fill against the notification needs the levels the strategy actually set,
    # not a display approximation of them.
    it "forwards the unrounded figures to Slack" do
      expect(SlackNotificationService).to receive(:signal_generated).with(
        {
          symbol: contract.product_id,
          side: :long,
          price: 50_800.126,
          quantity: 2,
          tp: 51_000.987,
          sl: 50_600.454,
          confidence: 85.5
        }
      )

      job.perform(equity_usd: 25_000.0)
    end

    it "captures the rounded signal to PostHog, tagged paper while paper trading" do
      job.perform(equity_usd: 25_000.0)

      expect(PostHog).to have_received(:capture).with(
        distinct_id: "system",
        event: "signal_generated",
        properties: {
          symbol: contract.product_id,
          side: :long,
          price: 50_800.13,
          quantity: 2,
          tp: 51_000.99,
          sl: 50_600.45,
          confidence: 85.5,
          paper_trading: true
        }
      )
    end

    # paper_trading is the field that records whether a signal was actually
    # acted on. If it ever inverts, every downstream funnel silently blends
    # live and paper signals with no other symptom.
    it "tags the capture as live when the executor is reached" do
      allow(ENV).to receive(:[]).with("PAPER_TRADING_MODE").and_return("false")
      allow(DryRun).to receive(:active?).and_return(false)
      allow(Execution::FuturesExecutor).to receive(:new)
        .and_return(instance_double(Execution::FuturesExecutor, consider_entry: nil))

      job.perform(equity_usd: 25_000.0)

      expect(PostHog).to have_received(:capture).with(
        distinct_id: "system",
        event: "signal_generated",
        properties: hash_including(paper_trading: false)
      )
    end

    it "sends nothing downstream when the strategy declines to signal" do
      allow(mock_strategy).to receive(:signal).and_return(nil)

      job.perform(equity_usd: 25_000.0)

      expect(SlackNotificationService).not_to have_received(:signal_generated)
      expect(PostHog).not_to have_received(:capture)
    end
  end

  # The job must build its strategy through Trading::StrategyFactory rather than
  # constructing MultiTimeframeSignal itself. Drift audit 2026-07-21: this job
  # hardcoded EMA periods and leaked class-DEFAULT tp/sl into Slack, so the
  # levels operators saw were not the levels the live profile traded. The
  # factory is the single builder shared with the realtime evaluator,
  # calibration, and the backtest engine — bypassing it is exactly how offline
  # results stop describing online behaviour.
  describe "strategy construction" do
    it "builds the strategy through StrategyFactory rather than by hand" do
      allow(Trading::StrategyFactory).to receive(:multi_timeframe).and_return(mock_strategy)
      allow(mock_strategy).to receive(:signal).and_return(nil)

      job.perform(equity_usd: 10_000.0)

      expect(Trading::StrategyFactory).to have_received(:multi_timeframe)
    end
  end
end
