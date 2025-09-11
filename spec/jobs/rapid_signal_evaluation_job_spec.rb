# frozen_string_literal: true

require "rails_helper"

RSpec.describe RapidSignalEvaluationJob, type: :job do
  let(:product_id) { "BTC-USD" }
  let(:current_price) { 50_000.0 }
  let(:asset) { "BTC" }

  describe "#perform" do
    context "with default day_trading configuration" do
      it "creates day trading position when DEFAULT_DAY_TRADING is true" do
        allow(Rails.application.config).to receive(:default_day_trading).and_return(true)

        # Mock dependencies
        allow_any_instance_of(Strategy::MultiTimeframeSignal).to receive(:signal).and_return({
          side: "LONG",
          quantity: 2,
          price: current_price,
          confidence: 80,
          tp: 50_200.0,
          sl: 49_800.0
        })

        allow_any_instance_of(MarketData::FuturesContractManager).to receive(:current_month_contract).and_return("BIT-29AUG25-CDE")
        allow_any_instance_of(Trading::CoinbasePositions).to receive(:open_position).and_return({success: true})

        expect {
          described_class.perform_now(
            product_id: product_id,
            current_price: current_price,
            asset: asset
          )
        }.to change(Position, :count).by(1)

        position = Position.last
        expect(position.day_trading).to be true
      end

      it "creates swing trading position when day_trading: false is explicitly passed" do
        allow(Rails.application.config).to receive(:default_day_trading).and_return(true)

        # Mock dependencies
        allow_any_instance_of(Strategy::MultiTimeframeSignal).to receive(:signal).and_return({
          side: "LONG",
          quantity: 2,
          price: current_price,
          confidence: 80,
          tp: 50_200.0,
          sl: 49_800.0
        })

        allow_any_instance_of(MarketData::FuturesContractManager).to receive(:current_month_contract).and_return("BIT-29AUG25-CDE")
        allow_any_instance_of(Trading::CoinbasePositions).to receive(:open_position).and_return({success: true})

        expect {
          described_class.perform_now(
            product_id: product_id,
            current_price: current_price,
            asset: asset,
            day_trading: false
          )
        }.to change(Position, :count).by(1)

        position = Position.last
        expect(position.day_trading).to be false
      end
    end

    context "with swing trading default configuration" do
      it "creates swing trading position when DEFAULT_DAY_TRADING is false" do
        allow(Rails.application.config).to receive(:default_day_trading).and_return(false)

        # Mock dependencies
        allow_any_instance_of(Strategy::MultiTimeframeSignal).to receive(:signal).and_return({
          side: "LONG",
          quantity: 2,
          price: current_price,
          confidence: 80,
          tp: 50_200.0,
          sl: 49_800.0
        })

        allow_any_instance_of(MarketData::FuturesContractManager).to receive(:current_month_contract).and_return("BIT-29AUG25-CDE")
        allow_any_instance_of(Trading::CoinbasePositions).to receive(:open_position).and_return({success: true})

        expect {
          described_class.perform_now(
            product_id: product_id,
            current_price: current_price,
            asset: asset
          )
        }.to change(Position, :count).by(1)

        position = Position.last
        expect(position.day_trading).to be false
      end

      it "creates day trading position when day_trading: true is explicitly passed" do
        allow(Rails.application.config).to receive(:default_day_trading).and_return(false)

        # Mock dependencies
        allow_any_instance_of(Strategy::MultiTimeframeSignal).to receive(:signal).and_return({
          side: "LONG",
          quantity: 2,
          price: current_price,
          confidence: 80,
          tp: 50_200.0,
          sl: 49_800.0
        })

        allow_any_instance_of(MarketData::FuturesContractManager).to receive(:current_month_contract).and_return("BIT-29AUG25-CDE")
        allow_any_instance_of(Trading::CoinbasePositions).to receive(:open_position).and_return({success: true})

        expect {
          described_class.perform_now(
            product_id: product_id,
            current_price: current_price,
            asset: asset,
            day_trading: true
          )
        }.to change(Position, :count).by(1)

        position = Position.last
        expect(position.day_trading).to be true
      end
    end

    context "when no signal is generated" do
      it "does not create a position" do
        allow_any_instance_of(Strategy::MultiTimeframeSignal).to receive(:signal).and_return(nil)
        allow_any_instance_of(MarketData::FuturesContractManager).to receive(:current_month_contract).and_return("BIT-29AUG25-CDE")

        expect {
          described_class.perform_now(
            product_id: product_id,
            current_price: current_price,
            asset: asset
          )
        }.not_to change(Position, :count)
      end
    end
  end
end
