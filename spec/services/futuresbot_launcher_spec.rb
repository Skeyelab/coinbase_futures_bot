# frozen_string_literal: true

require "rails_helper"

RSpec.describe FuturesBotLauncher do
  let(:logger) { instance_double(Logger) }
  let(:mock_tui) { double("tui", start: nil) }

  before do
    allow(logger).to receive(:info)
    allow(logger).to receive(:warn)
    allow(logger).to receive(:error)
    allow(mock_tui).to receive(:start)
  end

  subject(:launcher) do
    described_class.new(
      logger: logger,
      tui: mock_tui,
      skip_market_data: true,
      skip_signal_runner: true
    )
  end

  describe "#initialize" do
    it "accepts a custom tui" do
      expect(launcher.instance_variable_get(:@tui)).to eq(mock_tui)
    end

    it "defaults skip_market_data from env var" do
      ClimateControl.modify(FUTURESBOT_SKIP_MARKET_DATA: "1") do
        l = described_class.new(logger: logger, tui: mock_tui)
        expect(l.instance_variable_get(:@skip_market_data)).to be true
      end
    end

    it "defaults skip_signal_runner from env var" do
      ClimateControl.modify(FUTURESBOT_SKIP_SIGNAL_RUNNER: "1") do
        l = described_class.new(logger: logger, tui: mock_tui)
        expect(l.instance_variable_get(:@skip_signal_runner)).to be true
      end
    end

    it "reads signal interval from env var" do
      ClimateControl.modify(REALTIME_SIGNAL_EVALUATION_INTERVAL: "45") do
        l = described_class.new(logger: logger, tui: mock_tui)
        expect(l.instance_variable_get(:@signal_interval)).to eq(45)
      end
    end
  end

  describe "#start" do
    it "starts the TUI" do
      expect(mock_tui).to receive(:start)
      launcher.start
    end

    it "logs startup and shutdown messages" do
      expect(logger).to receive(:info).with(/Starting FuturesBot/)
      expect(logger).to receive(:info).with(/Launching TUI dashboard/)
      launcher.start
    end

    it "calls shutdown even when TUI raises" do
      allow(mock_tui).to receive(:start).and_raise(StandardError, "boom")
      expect(launcher).to receive(:shutdown).and_call_original
      expect { launcher.start }.to raise_error(StandardError, "boom")
    end

    context "when market data is not skipped" do
      let(:mock_spot) { instance_double(MarketData::CoinbaseSpotSubscriber) }
      let(:mock_futures) { instance_double(MarketData::CoinbaseFuturesSubscriber) }

      before do
        create(:contract, enabled: true, product_id: "BIT-29AUG25-CDE")
        allow(MarketData::CoinbaseSpotSubscriber).to receive(:new).and_return(mock_spot)
        allow(MarketData::CoinbaseFuturesSubscriber).to receive(:new).and_return(mock_futures)
        allow(mock_spot).to receive(:start)
        allow(mock_spot).to receive(:stop)
        allow(mock_futures).to receive(:start)
        allow(mock_futures).to receive(:stop)
      end

      subject(:launcher) do
        described_class.new(
          logger: logger,
          tui: mock_tui,
          skip_market_data: false,
          skip_signal_runner: true
        )
      end

      it "spawns a spot subscriber thread" do
        launcher.start
        expect(launcher.spot_thread).to be_a(Thread)
      end

      it "spawns a futures subscriber thread" do
        launcher.start
        expect(launcher.futures_thread).to be_a(Thread)
      end

      it "passes derived spot product ids and enabled futures product ids to subscribers" do
        # Intercept thread creation to run the block synchronously for inspection
        allow(Thread).to receive(:new).and_wrap_original do |original, &block|
          block.call
          original.call {} # return a no-op thread
        end
        launcher.start
        expect(MarketData::CoinbaseSpotSubscriber).to have_received(:new).with(
          hash_including(product_ids: ["BTC-USD"])
        )
        expect(MarketData::CoinbaseFuturesSubscriber).to have_received(:new).with(
          hash_including(product_ids: ["BIT-29AUG25-CDE"])
        )
      end

      context "when no trading pairs are enabled" do
        before { Contract.update_all(enabled: false) }

        it "logs a warning and skips subscription" do
          expect(logger).to receive(:warn).with(/No enabled trading pairs/)
          launcher.start
          expect(launcher.spot_thread).to be_nil
        end
      end
    end

    context "when signal runner is not skipped" do
      let(:mock_runner) { instance_double(RealtimeSignalRunner) }

      before do
        allow(RealtimeSignalRunner).to receive(:new).and_return(mock_runner)
        allow(mock_runner).to receive(:start!)
        allow(mock_runner).to receive(:tick)
      end

      subject(:launcher) do
        described_class.new(
          logger: logger,
          tui: mock_tui,
          skip_market_data: true,
          skip_signal_runner: false,
          signal_interval: 30
        )
      end

      it "spawns a signal runner thread" do
        launcher.start
        expect(launcher.signal_thread).to be_a(Thread)
      end

      it "passes the signal interval to the runner" do
        expect(RealtimeSignalRunner).to receive(:new).with(
          hash_including(interval_seconds: 30)
        ).and_return(mock_runner)
        launcher.start
      end
    end
  end

  describe "#shutdown" do
    it "kills threads that do not stop in time" do
      t = Thread.new { sleep 60 }
      launcher.instance_variable_set(:@spot_thread, t)
      launcher.shutdown
      expect(t.alive?).to be false
    end

    it "tolerates nil threads" do
      expect { launcher.shutdown }.not_to raise_error
    end

    it "stops subscribers cooperatively before killing threads" do
      spot_subscriber = instance_double(MarketData::CoinbaseSpotSubscriber, stop: true)
      futures_subscriber = instance_double(MarketData::CoinbaseFuturesSubscriber, stop: true)
      launcher.instance_variable_set(:@spot_subscriber, spot_subscriber)
      launcher.instance_variable_set(:@futures_subscriber, futures_subscriber)

      expect(spot_subscriber).to receive(:stop)
      expect(futures_subscriber).to receive(:stop)

      launcher.shutdown
    end
  end
end
