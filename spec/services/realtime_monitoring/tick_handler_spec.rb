# frozen_string_literal: true

require "rails_helper"

RSpec.describe RealtimeMonitoring::TickHandler do
  subject(:handler) { described_class.new(logger: logger, contract_manager: contract_manager) }

  let(:logger) { instance_double(Logger, info: nil, debug: nil, warn: nil) }
  let(:contract_manager) { instance_double(MarketData::FuturesContractManager) }

  before do
    allow(Rails.cache).to receive(:read)
    allow(Rails.cache).to receive(:write)
  end

  describe "#process" do
    let(:ticker_data) do
      {"product_id" => "BTC-USD", "price" => "50000.00", "time" => "2024-01-01T12:00:00Z"}
    end

    it "creates tick records and checks position alerts" do
      expect(Tick).to receive(:create!).with(hash_including(product_id: "BTC-USD", price: 50000.0))
      expect(handler).to receive(:check_position_alerts).with("BTC-USD", 50000.0)

      allow(handler).to receive(:spot_relevant?).and_return(false)
      allow(handler).to receive(:should_evaluate_signals?).and_return(false)

      handler.process(ticker_data)
    end

    it "skips invalid ticker data" do
      expect(Tick).not_to receive(:create!)

      handler.process("product_id" => "BTC-USD", "price" => "0", "time" => "2024-01-01T12:00:00Z")
    end

    describe "market-data liveness heartbeat" do
      before do
        allow(handler).to receive(:check_position_alerts)
        allow(handler).to receive(:spot_relevant?).and_return(false)
        allow(handler).to receive(:should_evaluate_signals?).and_return(false)
      end

      it "beats the market_data heartbeat on a valid tick so a dead WS feed is detectable" do
        expect(Heartbeat.status("market_data")[:stale]).to be(true)

        handler.process(ticker_data)

        expect(Heartbeat.status("market_data")[:stale]).to be(false)
      end

      it "also beats the realtime_signal heartbeat so the trading-loop status is not a false stale alarm" do
        # This monitoring loop (real_time:start) both ingests ticks and drives
        # signal evaluation — it IS the realtime loop — so it must beat the
        # realtime_signal heartbeat too, not just market_data.
        expect(Heartbeat.status("realtime_signal")[:stale]).to be(true)

        handler.process(ticker_data)

        expect(Heartbeat.status("realtime_signal")[:stale]).to be(false)
      end

      it "does not beat on invalid ticker data" do
        handler.process("product_id" => "BTC-USD", "price" => "0", "time" => ticker_data["time"])

        expect(Heartbeat.status("market_data")[:last_beat_at]).to be_nil
        expect(Heartbeat.status("realtime_signal")[:last_beat_at]).to be_nil
      end

      it "throttles beats so it does not write once per tick" do
        expect(Heartbeat).to receive(:beat!).with("market_data", anything).once
        expect(Heartbeat).to receive(:beat!).with("realtime_signal", anything).once

        3.times { handler.process(ticker_data) }
      end
    end
  end

  describe "#check_position_alerts" do
    let(:price) { 91.62 }

    it "checks exact futures contract positions" do
      product_id = "NOL-19JUN26-CDE"
      position = create(:position, product_id: product_id, take_profit: 92.0)

      expect(handler).to receive(:check_take_profit_stop_loss).with(position, price)
      allow(handler).to receive(:check_day_trading_time_limits)

      handler.send(:check_position_alerts, product_id, price)
    end
  end

  describe "#check_take_profit_stop_loss" do
    before do
      allow(handler).to receive(:trigger_position_close)
    end

    it "triggers take profit for long positions" do
      position = create(:position, take_profit: 92.0, stop_loss: 90.0)

      expect(handler).to receive(:trigger_position_close).with(position, "take_profit")

      handler.send(:check_take_profit_stop_loss, position, 92.0)
    end
  end

  describe "#trigger_position_close debounce" do
    it "does not re-enqueue a close for the same position within the cooldown" do
      position = create(:position)

      expect(PositionCloseJob).to receive(:perform_later).once

      handler.send(:trigger_position_close, position, "time_limit")
      handler.send(:trigger_position_close, position, "time_limit")
    end

    it "re-enqueues once the cooldown has elapsed" do
      position = create(:position)

      expect(PositionCloseJob).to receive(:perform_later).twice

      now = Time.current
      handler.send(:trigger_position_close, position, "time_limit", now: now)
      handler.send(:trigger_position_close, position, "time_limit", now: now + 61)
    end

    it "does not let one position's cooldown block another" do
      a = create(:position)
      b = create(:position)

      expect(PositionCloseJob).to receive(:perform_later).twice

      handler.send(:trigger_position_close, a, "time_limit")
      handler.send(:trigger_position_close, b, "time_limit")
    end
  end

  describe "#check_position_alerts adverse-excursion tracking" do
    it "records each open position's max adverse excursion on the tick" do
      product_id = "NOL-19JUN26-CDE"
      position = create(:position, product_id: product_id, side: "LONG", entry_price: 100.0, size: 1)
      allow(Trading::ContractSizeResolver).to receive(:for_product).with(product_id).and_return(10)

      handler.send(:check_position_alerts, product_id, 97.0) # (97-100)*1*10 = -30

      expect(position.reload.max_adverse_excursion).to eq(-30)
    end
  end

  describe "#check_dollar_pnl_exit (dollar-target + hard stop)" do
    let(:product_id) { "NOL-19JUN26-CDE" }

    def day_position
      create(:position, day_trading: true, side: "LONG", entry_price: 100.0, size: 1, product_id: product_id)
    end

    before do
      allow(handler).to receive(:trigger_position_close)
      # contract_size 10 → $ per $1 move per contract = 10
      allow(Trading::ContractSizeResolver).to receive(:for_product).with(product_id).and_return(10)
    end

    context "with dollar thresholds configured" do
      around do |ex|
        ClimateControl.modify(DOLLAR_PROFIT_TARGET_USD: "30", DOLLAR_STOP_LOSS_USD: "25") { ex.run }
      end

      it "closes at the profit target (price 104 → +$40 ≥ $30)" do
        position = day_position
        expect(handler).to receive(:trigger_position_close).with(position, "dollar_target")

        expect(handler.send(:check_dollar_pnl_exit, position, 104.0)).to be(true)
      end

      it "closes at the hard dollar stop (price 97 → -$30 ≤ -$25)" do
        position = day_position
        expect(handler).to receive(:trigger_position_close).with(position, "dollar_stop_loss")

        expect(handler.send(:check_dollar_pnl_exit, position, 97.0)).to be(true)
      end

      it "does nothing inside the dollar band (price 101 → +$10)" do
        position = day_position
        expect(handler).not_to receive(:trigger_position_close)

        expect(handler.send(:check_dollar_pnl_exit, position, 101.0)).to be(false)
      end

      it "ignores swing (non-day-trading) positions" do
        position = create(:position, day_trading: false, side: "LONG", entry_price: 100.0, size: 1, product_id: product_id)
        expect(handler).not_to receive(:trigger_position_close)

        expect(handler.send(:check_dollar_pnl_exit, position, 200.0)).to be(false)
      end
    end

    it "is inert when no dollar thresholds are configured" do
      position = day_position
      expect(handler).not_to receive(:trigger_position_close)

      expect(handler.send(:check_dollar_pnl_exit, position, 200.0)).to be(false)
    end
  end

  describe "#extract_asset_from_product_id" do
    it "extracts OIL from NOL futures contracts" do
      expect(handler.send(:extract_asset_from_product_id, "NOL-19JUN26-CDE")).to eq("OIL")
    end
  end

  describe "#update_futures_monitoring" do
    let(:current_contract) { "BIT-31JUL26-CDE" }
    let(:upcoming_contract) { "BIT-28AUG26-CDE" }

    before do
      allow(contract_manager).to receive(:current_month_contract).with("BTC").and_return(current_contract)
      allow(contract_manager).to receive(:upcoming_month_contract).with("BTC").and_return(upcoming_contract)
      allow(FuturesBasisMonitoringJob).to receive(:perform_later)
    end

    it "enqueues basis monitoring for each futures contract on first spot tick" do
      handler.send(:update_futures_monitoring, "BTC-USD", 50_000.0)

      expect(FuturesBasisMonitoringJob).to have_received(:perform_later).with(
        spot_product_id: "BTC-USD",
        futures_product_id: current_contract,
        spot_price: 50_000.0
      )
      expect(FuturesBasisMonitoringJob).to have_received(:perform_later).with(
        spot_product_id: "BTC-USD",
        futures_product_id: upcoming_contract,
        spot_price: 50_000.0
      )
    end

    it "rate limits basis monitoring jobs per spot and futures contract pair" do
      cache = {}
      allow(Rails.cache).to receive(:read) { |key| cache[key] }
      allow(Rails.cache).to receive(:write) { |key, value, **_opts| cache[key] = value }

      handler.send(:update_futures_monitoring, "BTC-USD", 50_000.0)
      handler.send(:update_futures_monitoring, "BTC-USD", 50_100.0)

      expect(FuturesBasisMonitoringJob).to have_received(:perform_later).twice
    end

    it "enqueues again after the rate limit window expires" do
      cache = {}
      allow(Rails.cache).to receive(:read) { |key| cache[key] }
      allow(Rails.cache).to receive(:write) { |key, value, **_opts| cache[key] = value }

      handler.send(:update_futures_monitoring, "BTC-USD", 50_000.0)

      travel 61.seconds do
        handler.send(:update_futures_monitoring, "BTC-USD", 50_200.0)
      end

      expect(FuturesBasisMonitoringJob).to have_received(:perform_later).exactly(4).times
    end
  end
end
