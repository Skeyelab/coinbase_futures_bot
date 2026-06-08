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

  describe "#extract_asset_from_product_id" do
    it "extracts OIL from NOL futures contracts" do
      expect(handler.send(:extract_asset_from_product_id, "NOL-19JUN26-CDE")).to eq("OIL")
    end
  end
end
