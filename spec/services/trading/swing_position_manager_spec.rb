# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trading::SwingPositionManager, type: :service do
  let(:logger) { instance_double(Logger) }
  let(:positions_service) { instance_double(Trading::CoinbasePositions) }
  let(:contract_manager) { instance_double(MarketData::FuturesContractManager) }
  let(:manager) { described_class.new(logger: logger) }

  before do
    allow(logger).to receive(:info)
    allow(logger).to receive(:warn)
    allow(logger).to receive(:error)
    allow(logger).to receive(:debug)
    allow(Trading::CoinbasePositions).to receive(:new).and_return(positions_service)
    allow(MarketData::FuturesContractManager).to receive(:new).and_return(contract_manager)
    allow(positions_service).to receive(:instance_variable_get).with(:@authenticated).and_return(true)
  end

  describe "#cleanup_old_positions" do
    let!(:old_position1) do
      create(:position,
        day_trading: false,
        status: "CLOSED",
        close_time: 35.days.ago,
        product_id: "BTC-USD-PERP",
        side: "LONG",
        size: 10)
    end

    let!(:old_position2) do
      create(:position,
        day_trading: false,
        status: "CLOSED",
        close_time: 40.days.ago,
        product_id: "ETH-USD-PERP",
        side: "SHORT",
        size: 5)
    end

    let!(:recent_position) do
      create(:position,
        day_trading: false,
        status: "CLOSED",
        close_time: 10.days.ago,
        product_id: "BTC-USD-PERP",
        side: "LONG",
        size: 8)
    end

    it "cleans up positions older than specified days" do
      result = manager.cleanup_old_positions(days_old: 30)

      expect(result).to eq(2)
      expect(Position.exists?(old_position1.id)).to be_falsey
      expect(Position.exists?(old_position2.id)).to be_falsey
      expect(Position.exists?(recent_position.id)).to be_truthy
    end

    it "logs the cleanup operation" do
      manager.cleanup_old_positions(days_old: 30)

      expect(logger).to have_received(:info).with("Found 2 old closed swing positions to clean up")
      expect(logger).to have_received(:info).with("Cleaned up 2 old closed swing positions")
    end

    it "uses default of 30 days if not specified" do
      allow(Position).to receive_message_chain(:swing_trading, :closed,
        :where).and_return(double(count: 0, each: [], delete_all: 0))

      manager.cleanup_old_positions

      expect(Position.swing_trading.closed).to have_received(:where).with("close_time < ?",
        be_within(1.second).of(30.days.ago))
    end
  end

  describe "#archive_completed_trades" do
    let!(:completed_trade1) do
      create(:position,
        day_trading: false,
        status: "CLOSED",
        close_time: 10.days.ago,
        product_id: "BTC-USD-PERP",
        side: "LONG",
        size: 10,
        entry_price: 50_000,
        pnl: 2000)
    end

    let!(:completed_trade2) do
      create(:position,
        day_trading: false,
        status: "CLOSED",
        close_time: 15.days.ago,
        product_id: "ETH-USD-PERP",
        side: "SHORT",
        size: 5,
        entry_price: 3000,
        pnl: 500)
    end

    let!(:very_old_trade) do
      create(:position,
        day_trading: false,
        status: "CLOSED",
        close_time: 100.days.ago,
        product_id: "BTC-USD-PERP",
        side: "LONG",
        size: 8)
    end

    it "archives completed trades within the specified range" do
      result = manager.archive_completed_trades(days_old: 7)

      expect(result).to eq(2)
      expect(logger).to have_received(:info).with("Found 2 completed swing trades to archive")
      expect(logger).to have_received(:info).with("Archived 2 completed swing trades")
    end

    it "logs trade summaries during archiving" do
      manager.archive_completed_trades(days_old: 7)

      expect(logger).to have_received(:info).with(match(/Archived swing trade summary.*BTC-USD-PERP/))
      expect(logger).to have_received(:info).with(match(/Archived swing trade summary.*ETH-USD-PERP/))
    end

    it "handles errors during individual trade archiving" do
      allow(manager).to receive(:archive_trade_summary).and_raise(StandardError, "Archive failed")

      result = manager.archive_completed_trades(days_old: 7)

      expect(result).to eq(0)
      expect(logger).to have_received(:error).with(/Failed to archive swing trade.*Archive failed/).twice
    end
  end

  describe "#positions_exceeding_max_hold?" do
    context "with positions exceeding max hold" do
      before do
        create(:position,
          day_trading: false,
          status: "OPEN",
          entry_time: 6.days.ago,
          product_id: "BTC-USD-PERP")
        allow(ENV).to receive(:fetch).with("SWING_MAX_HOLD_DAYS", 5).and_return("5")
      end

      it "returns true when positions exceed max hold period" do
        expect(manager.positions_exceeding_max_hold?).to be_truthy
      end
    end

    context "with no positions exceeding max hold" do
      before do
        create(:position,
          day_trading: false,
          status: "OPEN",
          entry_time: 2.days.ago,
          product_id: "BTC-USD-PERP")
        allow(ENV).to receive(:fetch).with("SWING_MAX_HOLD_DAYS", 5).and_return("5")
      end

      it "returns false when no positions exceed max hold period" do
        expect(manager.positions_exceeding_max_hold?).to be_falsey
      end
    end
  end

  describe "#positions_approaching_expiry?" do
    let(:trading_pair) { create(:trading_pair, product_id: "BTC-USD-PERP", expiration_date: 1.day.from_now) }

    context "with positions approaching expiry" do
      before do
        create(:position,
          day_trading: false,
          status: "OPEN",
          product_id: trading_pair.product_id,
          trading_pair: trading_pair)
        allow(ENV).to receive(:fetch).with("SWING_EXPIRY_BUFFER_DAYS", 2).and_return("2")
      end

      it "returns true when positions are approaching contract expiry" do
        expect(manager.positions_approaching_expiry?).to be_truthy
      end
    end

    context "with no positions approaching expiry" do
      let(:trading_pair) { create(:trading_pair, product_id: "BTC-USD-PERP", expiration_date: 10.days.from_now) }

      before do
        create(:position,
          day_trading: false,
          status: "OPEN",
          product_id: trading_pair.product_id,
          trading_pair: trading_pair)
        allow(ENV).to receive(:fetch).with("SWING_EXPIRY_BUFFER_DAYS", 2).and_return("2")
      end

      it "returns false when no positions are approaching expiry" do
        expect(manager.positions_approaching_expiry?).to be_falsey
      end
    end
  end

  describe "#archive_trade_summary" do
    let(:position) do
      create(:position,
        day_trading: false,
        status: "CLOSED",
        product_id: "BTC-USD-PERP",
        side: "LONG",
        size: 10,
        entry_price: 50_000,
        entry_time: 2.days.ago,
        close_time: 1.day.ago,
        pnl: 2000)
    end

    it "logs trade summary with all relevant data" do
      manager.send(:archive_trade_summary, position)

      expect(logger).to have_received(:info).with(match(/Archived swing trade summary.*BTC-USD-PERP.*LONG.*10.*50000.*2000/))
    end

    it "includes timestamp in archived data" do
      # Use a fixed time to avoid timing issues
      fixed_time = Time.parse("2025-01-18 12:00:00 UTC")
      allow(Time).to receive(:current).and_return(fixed_time)

      manager.send(:archive_trade_summary, position)

      expect(logger).to have_received(:info).with(match(/archived_at.*#{fixed_time.iso8601}/))
    end
  end

  describe "configuration" do
    context "with environment variables set" do
      before do
        allow(ENV).to receive(:fetch).with("SWING_MAX_HOLD_DAYS", 5).and_return("7")
        allow(ENV).to receive(:fetch).with("SWING_EXPIRY_BUFFER_DAYS", 2).and_return("3")
        allow(ENV).to receive(:fetch).with("SWING_MAX_EXPOSURE", 0.3).and_return("0.4")
        allow(ENV).to receive(:fetch).with("SWING_ENABLE_ROLL", false).and_return("true")
        allow(ENV).to receive(:fetch).with("SWING_MARGIN_BUFFER", 0.2).and_return("0.25")
        allow(ENV).to receive(:fetch).with("SWING_MAX_LEVERAGE", 3).and_return("4")
      end

      it "uses environment variable configuration" do
        config = manager.send(:default_config)

        expect(config[:max_hold_days]).to eq(7)
        expect(config[:expiry_buffer_days]).to eq(3)
        expect(config[:max_overnight_exposure]).to eq(0.4)
        expect(config[:enable_contract_roll]).to eq("true")
        expect(config[:margin_safety_buffer]).to eq(0.25)
        expect(config[:max_leverage_overnight]).to eq(4)
      end
    end

    context "with default values" do
      before do
        allow(ENV).to receive(:fetch).with("SWING_MAX_HOLD_DAYS", 5).and_return("5")
        allow(ENV).to receive(:fetch).with("SWING_EXPIRY_BUFFER_DAYS", 2).and_return("2")
        allow(ENV).to receive(:fetch).with("SWING_MAX_EXPOSURE", 0.3).and_return("0.3")
        allow(ENV).to receive(:fetch).with("SWING_ENABLE_ROLL", false).and_return("false")
        allow(ENV).to receive(:fetch).with("SWING_MARGIN_BUFFER", 0.2).and_return("0.2")
        allow(ENV).to receive(:fetch).with("SWING_MAX_LEVERAGE", 3).and_return("3")
      end

      it "uses default configuration values" do
        config = manager.send(:default_config)

        expect(config[:max_hold_days]).to eq(5)
        expect(config[:expiry_buffer_days]).to eq(2)
        expect(config[:max_overnight_exposure]).to eq(0.3)
        expect(config[:enable_contract_roll]).to eq("false")
        expect(config[:margin_safety_buffer]).to eq(0.2)
        expect(config[:max_leverage_overnight]).to eq(3)
      end
    end
  end
end
