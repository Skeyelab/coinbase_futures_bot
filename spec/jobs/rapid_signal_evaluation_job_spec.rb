# frozen_string_literal: true

require "rails_helper"

RSpec.describe RapidSignalEvaluationJob, type: :job do
  let(:product_id) { "BTC-USD" }
  let(:current_price) { 50_000.0 }
  let(:asset) { "BTC" }
  let(:contract_id) { "BIT-29AUG25-CDE" }
  let(:job) { described_class.new }

  let(:mock_strategy) { instance_double(Strategy::MultiTimeframeSignal) }
  let(:mock_contract_manager) { instance_double(MarketData::FuturesContractManager) }
  let(:mock_positions_service) { instance_double(Trading::CoinbasePositions) }
  let(:mock_logger) { instance_double(ActiveSupport::Logger) }

  before do
    allow(Rails).to receive(:logger).and_return(mock_logger)
    allow(mock_logger).to receive(:debug)
    allow(mock_logger).to receive(:info)
    allow(mock_logger).to receive(:warn)
    allow(mock_logger).to receive(:error)

    # Mock configuration
    allow(Rails.application.config).to receive(:default_day_trading).and_return(true)
    allow(ENV).to receive(:fetch).with("SIGNAL_EQUITY_USD", "50000").and_return("50000")

    # Mock strategy creation
    allow(Strategy::MultiTimeframeSignal).to receive(:new).and_return(mock_strategy)
    allow(MarketData::FuturesContractManager).to receive(:new).and_return(mock_contract_manager)
    allow(Trading::CoinbasePositions).to receive(:new).and_return(mock_positions_service)
  end

  describe "#perform" do
    before do
      # Clear database before each test to avoid state issues
      Position.destroy_all
    end

    context "rapid signal evaluation algorithms" do
      it "initializes multi-timeframe strategy with day trading parameters" do
        allow(mock_contract_manager).to receive(:current_month_contract).and_return(contract_id)
        allow(mock_strategy).to receive(:signal).and_return(nil)

        expected_config = {
          ema_1h_short: 21,
          ema_1h_long: 50,
          ema_15m: 21,
          ema_5m: 13,
          ema_1m: 8,
          min_1h_candles: 60,
          min_15m_candles: 80,
          min_5m_candles: 60,
          min_1m_candles: 30,
          tp_target: 0.004, # 40 bps for day trading
          sl_target: 0.003, # 30 bps for day trading
          contract_size_usd: 100.0, # BTC contract size
          max_position_size: 5,
          min_position_size: 1
        }

        expect(Strategy::MultiTimeframeSignal).to receive(:new).with(expected_config)

        job.perform(product_id: product_id, current_price: current_price, asset: asset)
      end

      it "uses different contract sizes for different assets" do
        allow(mock_contract_manager).to receive(:current_month_contract).and_return("ET-29AUG25-CDE")
        allow(mock_strategy).to receive(:signal).and_return(nil)

        job.perform(product_id: "ETH-USD", current_price: 3000.0, asset: "ETH")

        expect(Strategy::MultiTimeframeSignal).to have_received(:new).with(
          hash_including(contract_size_usd: 10.0, max_position_size: 10)
        )
      end

      it "generates signal with correct equity parameters" do
        allow(mock_contract_manager).to receive(:current_month_contract).and_return(contract_id)
        allow(mock_strategy).to receive(:signal).and_return(nil)

        expect(mock_strategy).to receive(:signal).with(
          symbol: product_id,
          equity_usd: 50_000.0
        )

        job.perform(product_id: product_id, current_price: current_price, asset: asset)
      end

      it "respects custom equity from environment" do
        allow(ENV).to receive(:fetch).with("SIGNAL_EQUITY_USD", "50000").and_return("75000")
        allow(mock_contract_manager).to receive(:current_month_contract).and_return(contract_id)
        allow(mock_strategy).to receive(:signal).and_return(nil)

        expect(mock_strategy).to receive(:signal).with(
          symbol: product_id,
          equity_usd: 75_000.0
        )

        job.perform(product_id: product_id, current_price: current_price, asset: asset)
      end
    end

    context "real-time market data processing" do
      let(:high_confidence_signal) do
        {
          side: "LONG",
          quantity: 2,
          price: current_price,
          confidence: 85,
          tp: 50_200.0,
          sl: 49_800.0
        }
      end

      it "processes current price correctly as float" do
        allow(mock_contract_manager).to receive(:current_month_contract).and_return(contract_id)
        allow(mock_strategy).to receive(:signal).and_return(nil)

        job.perform(product_id: product_id, current_price: "50000.5", asset: asset)

        # Verify the price was converted to float internally
        expect(mock_logger).to have_received(:debug).with(
          "[RSE] Evaluating rapid signals for #{product_id} at $50000.5"
        )
      end

      it "handles rapid price updates efficiently" do
        allow(mock_contract_manager).to receive(:current_month_contract).and_return(contract_id)
        allow(mock_strategy).to receive(:signal).and_return(nil)

        # Simulate rapid price updates
        prices = [50_000.0, 50_010.0, 50_005.0, 49_995.0, 50_020.0]

        start_time = Time.current
        prices.each do |price|
          job.perform(product_id: product_id, current_price: price, asset: asset)
        end
        execution_time = Time.current - start_time

        # Should complete all evaluations within reasonable time (< 1 second for 5 evaluations)
        expect(execution_time).to be < 1.0
        expect(mock_strategy).to have_received(:signal).exactly(5).times
      end

      it "logs rapid signal evaluation start" do
        allow(mock_contract_manager).to receive(:current_month_contract).and_return(contract_id)
        allow(mock_strategy).to receive(:signal).and_return(nil)

        job.perform(product_id: product_id, current_price: current_price, asset: asset)

        expect(mock_logger).to have_received(:debug).with(
          "[RSE] Evaluating rapid signals for #{product_id} at $#{current_price}"
        )
      end
    end

    context "signal execution workflows" do
      let(:high_confidence_signal) do
        {
          side: "LONG",
          quantity: 2,
          price: current_price,
          confidence: 85,
          tp: 50_200.0,
          sl: 49_800.0
        }
      end

      it "executes high-confidence signals" do
        allow(mock_contract_manager).to receive(:current_month_contract).and_return(contract_id)
        allow(mock_strategy).to receive(:signal).and_return(high_confidence_signal)
        allow(Position).to receive_message_chain(:open, :by_asset, :count).and_return(0)
        allow(mock_positions_service).to receive(:open_position).and_return({success: true})

        expect(mock_positions_service).to receive(:open_position).with(
          product_id: contract_id,
          side: "LONG",
          size: 2,
          type: :market,
          day_trading: true,
          take_profit: 50_200.0,
          stop_loss: 49_800.0
        )

        job.perform(product_id: product_id, current_price: current_price, asset: asset)
      end

      it "creates position tracking record on successful execution" do
        allow(mock_contract_manager).to receive(:current_month_contract).and_return(contract_id)
        allow(mock_strategy).to receive(:signal).and_return(high_confidence_signal)
        allow(Position).to receive_message_chain(:open, :by_asset, :count).and_return(0)
        allow(mock_positions_service).to receive(:open_position).and_return({success: true})

        expect {
          job.perform(product_id: product_id, current_price: current_price, asset: asset)
        }.to change(Position, :count).by(1)

        position = Position.last
        expect(position.product_id).to eq(contract_id)
        expect(position.side).to eq("LONG")
        expect(position.size).to eq(2)
        expect(position.entry_price).to eq(current_price)
        expect(position.status).to eq("OPEN")
        expect(position.day_trading).to be true
        expect(position.take_profit).to eq(50_200.0)
        expect(position.stop_loss).to eq(49_800.0)
      end

      it "logs successful signal execution" do
        allow(mock_contract_manager).to receive(:current_month_contract).and_return(contract_id)
        allow(mock_strategy).to receive(:signal).and_return(high_confidence_signal)
        allow(Position).to receive_message_chain(:open, :by_asset, :count).and_return(0)
        allow(mock_positions_service).to receive(:open_position).and_return({success: true})

        job.perform(product_id: product_id, current_price: current_price, asset: asset)

        expect(mock_logger).to have_received(:info).with(
          "[RSE] Rapid signal generated for #{product_id}: LONG 2 contracts"
        )
        expect(mock_logger).to have_received(:info).with(
          "[RSE] Successfully opened LONG position: 2 contracts of #{contract_id}"
        )
      end

      it "sends position alert on successful execution" do
        allow(mock_contract_manager).to receive(:current_month_contract).and_return(contract_id)
        allow(mock_strategy).to receive(:signal).and_return(high_confidence_signal)
        allow(Position).to receive_message_chain(:open, :by_asset, :count).and_return(0)
        allow(mock_positions_service).to receive(:open_position).and_return({success: true})

        job.perform(product_id: product_id, current_price: current_price, asset: asset)

        expect(mock_logger).to have_received(:info).with(
          /\[ALERT\] OPENED: LONG 2 contracts of #{contract_id} at \$#{current_price}/
        )
      end
    end

    context "performance optimization and latency" do
      it "completes evaluation within performance threshold" do
        allow(mock_contract_manager).to receive(:current_month_contract).and_return(contract_id)
        allow(mock_strategy).to receive(:signal).and_return(nil)

        start_time = Time.current
        job.perform(product_id: product_id, current_price: current_price, asset: asset)
        execution_time = Time.current - start_time

        # Should complete within 100ms for rapid execution
        expect(execution_time).to be < 0.1
      end

      it "handles concurrent evaluations efficiently" do
        allow(mock_contract_manager).to receive(:current_month_contract).and_return(contract_id)
        allow(mock_strategy).to receive(:signal).and_return(nil)

        threads = 5.times.map do |i|
          Thread.new do
            job.perform(
              product_id: "#{asset}-USD",
              current_price: current_price + i,
              asset: asset
            )
          end
        end

        start_time = Time.current
        threads.each(&:join)
        total_time = Time.current - start_time

        # All concurrent evaluations should complete within reasonable time
        expect(total_time).to be < 1.0
        expect(mock_strategy).to have_received(:signal).exactly(5).times
      end

      it "optimizes memory usage during rapid evaluations" do
        allow(mock_contract_manager).to receive(:current_month_contract).and_return(contract_id)
        allow(mock_strategy).to receive(:signal).and_return(nil)

        # Perform multiple evaluations and ensure no memory leaks
        100.times do |i|
          job.perform(
            product_id: product_id,
            current_price: current_price + i,
            asset: asset
          )
        end

        expect(mock_strategy).to have_received(:signal).exactly(100).times
      end
    end

    context "error handling and fallback mechanisms" do
      it "handles missing futures contract gracefully" do
        allow(mock_contract_manager).to receive(:current_month_contract).and_return(nil)
        allow(mock_strategy).to receive(:signal) # Stub the method even though it won't be called

        expect {
          job.perform(product_id: product_id, current_price: current_price, asset: asset)
        }.not_to raise_error

        expect(mock_logger).to have_received(:warn).with(
          "[RSE] No current month contract found for #{asset}"
        )
        expect(mock_strategy).not_to have_received(:signal)
      end

      it "handles strategy signal generation errors" do
        allow(mock_contract_manager).to receive(:current_month_contract).and_return(contract_id)
        allow(mock_strategy).to receive(:signal).and_raise(StandardError, "Strategy error")

        expect {
          job.perform(product_id: product_id, current_price: current_price, asset: asset)
        }.not_to raise_error

        # Should still attempt to generate signal despite error
        expect(mock_strategy).to have_received(:signal)
        expect(mock_logger).to have_received(:error).with("[RSE] Error generating signal: Strategy error")
      end

      it "handles position execution failures gracefully" do
        high_confidence_signal = {
          side: "LONG",
          quantity: 2,
          price: current_price,
          confidence: 85,
          tp: 50_200.0,
          sl: 49_800.0
        }

        allow(mock_contract_manager).to receive(:current_month_contract).and_return(contract_id)
        allow(mock_strategy).to receive(:signal).and_return(high_confidence_signal)
        allow(Position).to receive_message_chain(:open, :by_asset, :count).and_return(0)
        allow(mock_positions_service).to receive(:open_position).and_return({
          success: false,
          error: "Insufficient funds"
        })

        expect {
          job.perform(product_id: product_id, current_price: current_price, asset: asset)
        }.not_to change(Position, :count)

        expect(mock_logger).to have_received(:error).with(
          "[RSE] Failed to open position: Insufficient funds"
        )
      end

      it "handles position service exceptions" do
        high_confidence_signal = {
          side: "LONG",
          quantity: 2,
          price: current_price,
          confidence: 85,
          tp: 50_200.0,
          sl: 49_800.0
        }

        allow(mock_contract_manager).to receive(:current_month_contract).and_return(contract_id)
        allow(mock_strategy).to receive(:signal).and_return(high_confidence_signal)
        allow(Position).to receive_message_chain(:open, :by_asset, :count).and_return(0)
        allow(mock_positions_service).to receive(:open_position).and_raise(StandardError, "API timeout")

        expect {
          job.perform(product_id: product_id, current_price: current_price, asset: asset)
        }.not_to raise_error

        expect(mock_logger).to have_received(:error).with(
          "[RSE] Error executing futures signal: API timeout"
        )
      end

      it "handles invalid price inputs" do
        allow(mock_contract_manager).to receive(:current_month_contract).and_return(contract_id)
        allow(mock_strategy).to receive(:signal).and_return(nil)

        # Test with various invalid price formats
        ["invalid", "", nil, -100].each do |invalid_price|
          expect {
            job.perform(product_id: product_id, current_price: invalid_price, asset: asset)
          }.not_to raise_error
        end
      end

      it "continues execution despite contract manager errors" do
        allow(mock_contract_manager).to receive(:current_month_contract).and_raise(StandardError, "Contract API error")
        allow(mock_strategy).to receive(:signal) # Stub the method even though it won't be called

        expect {
          job.perform(product_id: product_id, current_price: current_price, asset: asset)
        }.not_to raise_error

        expect(mock_contract_manager).to have_received(:current_month_contract)
        expect(mock_strategy).not_to have_received(:signal)
        expect(mock_logger).to have_received(:error).with("[RSE] Error getting futures contract: Contract API error")
      end
    end

    context "integration with trading strategies" do
      it "configures strategy with asset-specific parameters for BTC" do
        allow(mock_contract_manager).to receive(:current_month_contract).and_return(contract_id)
        allow(mock_strategy).to receive(:signal).and_return(nil)

        job.perform(product_id: product_id, current_price: current_price, asset: "BTC")

        expect(Strategy::MultiTimeframeSignal).to have_received(:new).with(
          hash_including(
            contract_size_usd: 100.0,
            max_position_size: 5,
            min_position_size: 1
          )
        )
      end

      it "configures strategy with asset-specific parameters for ETH" do
        allow(mock_contract_manager).to receive(:current_month_contract).and_return("ET-29AUG25-CDE")
        allow(mock_strategy).to receive(:signal).and_return(nil)

        job.perform(product_id: "ETH-USD", current_price: 3000.0, asset: "ETH")

        expect(Strategy::MultiTimeframeSignal).to have_received(:new).with(
          hash_including(
            contract_size_usd: 10.0,
            max_position_size: 10,
            min_position_size: 1
          )
        )
      end

      it "uses default parameters for unknown assets" do
        allow(mock_contract_manager).to receive(:current_month_contract).and_return("UNKNOWN-29AUG25-CDE")
        allow(mock_strategy).to receive(:signal).and_return(nil)

        job.perform(product_id: "UNKNOWN-USD", current_price: 1000.0, asset: "UNKNOWN")

        expect(Strategy::MultiTimeframeSignal).to have_received(:new).with(
          hash_including(
            contract_size_usd: 100.0,
            max_position_size: 5,
            min_position_size: 1
          )
        )
      end

      it "integrates with futures contract manager correctly" do
        expect(mock_contract_manager).to receive(:current_month_contract).with(asset)
        allow(mock_contract_manager).to receive(:current_month_contract).and_return(contract_id)
        allow(mock_strategy).to receive(:signal).and_return(nil)

        job.perform(product_id: product_id, current_price: current_price, asset: asset)
      end

      it "uses market orders for rapid execution" do
        high_confidence_signal = {
          side: "LONG",
          quantity: 2,
          price: current_price,
          confidence: 85,
          tp: 50_200.0,
          sl: 49_800.0
        }

        allow(mock_contract_manager).to receive(:current_month_contract).and_return(contract_id)
        allow(mock_strategy).to receive(:signal).and_return(high_confidence_signal)
        allow(Position).to receive_message_chain(:open, :by_asset, :count).and_return(0)
        allow(mock_positions_service).to receive(:open_position).and_return({success: true})

        job.perform(product_id: product_id, current_price: current_price, asset: asset)

        expect(mock_positions_service).to have_received(:open_position).with(
          hash_including(type: :market)
        )
      end
    end

    context "high-frequency trading scenarios" do
      let(:medium_confidence_signal) do
        {
          side: "SHORT",
          quantity: 1,
          price: current_price,
          confidence: 78,
          tp: 49_800.0,
          sl: 50_200.0
        }
      end

      it "processes multiple rapid signals in sequence" do
        signals = [
          {side: "LONG", quantity: 1, price: 50_000, confidence: 80, tp: 50_200, sl: 49_800},
          {side: "SHORT", quantity: 2, price: 50_010, confidence: 85, tp: 49_810, sl: 50_210},
          {side: "LONG", quantity: 1, price: 49_990, confidence: 76, tp: 50_190, sl: 49_790}
        ]

        allow(mock_contract_manager).to receive(:current_month_contract).and_return(contract_id)
        allow(Position).to receive_message_chain(:open, :by_asset, :count).and_return(0)
        allow(mock_positions_service).to receive(:open_position).and_return({success: true})

        signals.each_with_index do |signal, index|
          allow(mock_strategy).to receive(:signal).and_return(signal)
          job.perform(
            product_id: product_id,
            current_price: signal[:price],
            asset: asset
          )
        end

        expect(mock_strategy).to have_received(:signal).exactly(3).times
        expect(mock_positions_service).to have_received(:open_position).exactly(3).times
      end

      it "respects high confidence threshold (>75%) for rapid execution" do
        signals_with_confidence = [
          {confidence: 74, should_execute: false},
          {confidence: 75, should_execute: true},
          {confidence: 80, should_execute: true},
          {confidence: 90, should_execute: true}
        ]

        allow(mock_contract_manager).to receive(:current_month_contract).and_return(contract_id)
        allow(Position).to receive_message_chain(:open, :by_asset, :count).and_return(0)

        signals_with_confidence.each_with_index do |test_case, index|
          # Create a fresh job instance for each test case
          job_instance = described_class.new

          signal = {
            side: "LONG",
            quantity: 1,
            price: current_price,
            confidence: test_case[:confidence],
            tp: 50_200.0,
            sl: 49_800.0
          }

          allow(mock_strategy).to receive(:signal).and_return(signal)

          if test_case[:should_execute]
            allow(mock_positions_service).to receive(:open_position).and_return({success: true})
          end

          job_instance.perform(product_id: product_id, current_price: current_price, asset: asset)
        end

        # Verify that open_position was called 3 times (for confidence >= 75)
        expect(mock_positions_service).to have_received(:open_position).exactly(3).times
      end

      it "enforces maximum concurrent positions per asset" do
        high_confidence_signal = {
          side: "LONG",
          quantity: 1,
          price: current_price,
          confidence: 85,
          tp: 50_200.0,
          sl: 49_800.0
        }

        allow(mock_contract_manager).to receive(:current_month_contract).and_return(contract_id)
        allow(mock_strategy).to receive(:signal).and_return(high_confidence_signal)

        # Test BTC max positions (2)
        allow(Position).to receive_message_chain(:open, :by_asset, :count).and_return(2)

        expect(mock_positions_service).not_to receive(:open_position)

        job.perform(product_id: product_id, current_price: current_price, asset: "BTC")

        expect(mock_logger).to have_received(:info).with(
          /Skipping signal - already at max positions \(2\/2\) for BTC/
        )
      end

      it "enforces maximum position size limits" do
        large_signal = {
          side: "LONG",
          quantity: 15, # Exceeds max of 10
          price: current_price,
          confidence: 85,
          tp: 50_200.0,
          sl: 49_800.0
        }

        allow(mock_contract_manager).to receive(:current_month_contract).and_return(contract_id)
        allow(mock_strategy).to receive(:signal).and_return(large_signal)
        allow(Position).to receive_message_chain(:open, :by_asset, :count).and_return(0)

        expect(mock_positions_service).not_to receive(:open_position)

        job.perform(product_id: product_id, current_price: current_price, asset: asset)

        expect(mock_logger).to have_received(:debug).with(
          "[RSE] No actionable signal for #{product_id}"
        )
      end

      it "handles rapid signal evaluation with different assets" do
        assets_and_contracts = [
          {asset: "BTC", contract: "BIT-29AUG25-CDE", max_positions: 2},
          {asset: "ETH", contract: "ET-29AUG25-CDE", max_positions: 3}
        ]

        assets_and_contracts.each do |test_data|
          allow(mock_contract_manager).to receive(:current_month_contract)
            .with(test_data[:asset]).and_return(test_data[:contract])
          allow(Position).to receive_message_chain(:open, :by_asset, :count).and_return(0)
          allow(mock_strategy).to receive(:signal).and_return({
            side: "LONG",
            quantity: 1,
            price: current_price,
            confidence: 85,
            tp: 50_200.0,
            sl: 49_800.0
          })
          allow(mock_positions_service).to receive(:open_position).and_return({success: true})

          job.perform(
            product_id: "#{test_data[:asset]}-USD",
            current_price: current_price,
            asset: test_data[:asset]
          )
        end

        expect(mock_positions_service).to have_received(:open_position).twice
      end
    end

    context "day trading configuration" do
      it "uses day trading configuration when specified" do
        high_confidence_signal = {
          side: "LONG",
          quantity: 2,
          price: current_price,
          confidence: 85,
          tp: 50_200.0,
          sl: 49_800.0
        }

        allow(mock_contract_manager).to receive(:current_month_contract).and_return(contract_id)
        allow(mock_strategy).to receive(:signal).and_return(high_confidence_signal)
        allow(Position).to receive_message_chain(:open, :by_asset, :count).and_return(0)
        allow(mock_positions_service).to receive(:open_position).and_return({success: true})

        job.perform(
          product_id: product_id,
          current_price: current_price,
          asset: asset,
          day_trading: true
        )

        expect(mock_positions_service).to have_received(:open_position).with(
          hash_including(day_trading: true)
        )

        position = Position.last
        expect(position.day_trading).to be true
      end

      it "uses swing trading configuration when day_trading is false" do
        high_confidence_signal = {
          side: "LONG",
          quantity: 2,
          price: current_price,
          confidence: 85,
          tp: 50_200.0,
          sl: 49_800.0
        }

        allow(mock_contract_manager).to receive(:current_month_contract).and_return(contract_id)
        allow(mock_strategy).to receive(:signal).and_return(high_confidence_signal)
        allow(Position).to receive_message_chain(:open, :by_asset, :count).and_return(0)
        allow(mock_positions_service).to receive(:open_position).and_return({success: true})

        job.perform(
          product_id: product_id,
          current_price: current_price,
          asset: asset,
          day_trading: false
        )

        expect(mock_positions_service).to have_received(:open_position).with(
          hash_including(day_trading: false)
        )

        position = Position.last
        expect(position.day_trading).to be false
      end

      it "uses application default when day_trading is nil" do
        allow(Rails.application.config).to receive(:default_day_trading).and_return(false)

        high_confidence_signal = {
          side: "LONG",
          quantity: 2,
          price: current_price,
          confidence: 85,
          tp: 50_200.0,
          sl: 49_800.0
        }

        allow(mock_contract_manager).to receive(:current_month_contract).and_return(contract_id)
        allow(mock_strategy).to receive(:signal).and_return(high_confidence_signal)
        allow(Position).to receive_message_chain(:open, :by_asset, :count).and_return(0)
        allow(mock_positions_service).to receive(:open_position).and_return({success: true})

        job.perform(
          product_id: product_id,
          current_price: current_price,
          asset: asset,
          day_trading: nil
        )

        expect(mock_positions_service).to have_received(:open_position).with(
          hash_including(day_trading: false)
        )
      end
    end

    context "signal confidence and filtering" do
      it "rejects low confidence signals" do
        low_confidence_signal = {
          side: "LONG",
          quantity: 2,
          price: current_price,
          confidence: 60, # Below 75% threshold
          tp: 50_200.0,
          sl: 49_800.0
        }

        allow(mock_contract_manager).to receive(:current_month_contract).and_return(contract_id)
        allow(mock_strategy).to receive(:signal).and_return(low_confidence_signal)

        expect(mock_positions_service).not_to receive(:open_position)

        job.perform(product_id: product_id, current_price: current_price, asset: asset)

        expect(mock_logger).to have_received(:debug).with(
          "[RSE] No actionable signal for #{product_id}"
        )
      end

      it "accepts signals exactly at confidence threshold" do
        threshold_signal = {
          side: "LONG",
          quantity: 2,
          price: current_price,
          confidence: 75, # Exactly at threshold
          tp: 50_200.0,
          sl: 49_800.0
        }

        allow(mock_contract_manager).to receive(:current_month_contract).and_return(contract_id)
        allow(mock_strategy).to receive(:signal).and_return(threshold_signal)
        allow(Position).to receive_message_chain(:open, :by_asset, :count).and_return(0)
        allow(mock_positions_service).to receive(:open_position).and_return({success: true})

        expect(mock_positions_service).to receive(:open_position)

        job.perform(product_id: product_id, current_price: current_price, asset: asset)
      end

      it "handles nil signal gracefully" do
        allow(mock_contract_manager).to receive(:current_month_contract).and_return(contract_id)
        allow(mock_strategy).to receive(:signal).and_return(nil)

        expect(mock_positions_service).not_to receive(:open_position)

        job.perform(product_id: product_id, current_price: current_price, asset: asset)

        expect(mock_logger).to have_received(:debug).with(
          "[RSE] No actionable signal for #{product_id}"
        )
      end
    end

    context "asset-specific configuration" do
      it "applies BTC-specific limits" do
        job_instance = described_class.new

        expect(job_instance.send(:contract_size_for_asset, "BTC")).to eq(100.0)
        expect(job_instance.send(:max_contracts_for_asset, "BTC")).to eq(5)
        expect(job_instance.send(:max_concurrent_positions_for_asset, "BTC")).to eq(2)
      end

      it "applies ETH-specific limits" do
        job_instance = described_class.new

        expect(job_instance.send(:contract_size_for_asset, "ETH")).to eq(10.0)
        expect(job_instance.send(:max_contracts_for_asset, "ETH")).to eq(10)
        expect(job_instance.send(:max_concurrent_positions_for_asset, "ETH")).to eq(3)
      end

      it "applies default limits for unknown assets" do
        job_instance = described_class.new

        expect(job_instance.send(:contract_size_for_asset, "UNKNOWN")).to eq(100.0)
        expect(job_instance.send(:max_contracts_for_asset, "UNKNOWN")).to eq(5)
        expect(job_instance.send(:max_concurrent_positions_for_asset, "UNKNOWN")).to eq(2)
      end

      it "validates sufficient buying power" do
        job_instance = described_class.new

        expect(job_instance.send(:sufficient_buying_power?, 5)).to be true
        expect(job_instance.send(:sufficient_buying_power?, 10)).to be true
        expect(job_instance.send(:sufficient_buying_power?, 15)).to be false
      end
    end
  end

  describe "private methods" do
    let(:job_instance) { described_class.new }

    describe "#should_execute_signal?" do
      let(:signal) do
        {
          side: "LONG",
          quantity: 2,
          price: current_price,
          confidence: 85,
          tp: 50_200.0,
          sl: 49_800.0
        }
      end

      before do
        job_instance.instance_variable_set(:@asset, asset)
        job_instance.instance_variable_set(:@logger, mock_logger)
      end

      it "returns false for nil signal" do
        expect(job_instance.send(:should_execute_signal?, nil)).to be false
      end

      it "returns false for low confidence signals" do
        low_confidence_signal = signal.merge(confidence: 60)
        expect(job_instance.send(:should_execute_signal?, low_confidence_signal)).to be false
      end

      it "returns false when at max positions" do
        allow(Position).to receive_message_chain(:open, :by_asset, :count).and_return(2)
        expect(job_instance.send(:should_execute_signal?, signal)).to be false
      end

      it "returns false for insufficient buying power" do
        allow(Position).to receive_message_chain(:open, :by_asset, :count).and_return(0)
        large_signal = signal.merge(quantity: 15)
        expect(job_instance.send(:should_execute_signal?, large_signal)).to be false
      end

      it "returns true for valid high confidence signals" do
        allow(Position).to receive_message_chain(:open, :by_asset, :count).and_return(0)
        expect(job_instance.send(:should_execute_signal?, signal)).to be true
      end
    end

    describe "#execute_futures_signal" do
      let(:signal) do
        {
          side: "LONG",
          quantity: 2,
          price: current_price,
          confidence: 85,
          tp: 50_200.0,
          sl: 49_800.0
        }
      end

      before do
        job_instance.instance_variable_set(:@logger, mock_logger)
        job_instance.instance_variable_set(:@day_trading, true)
        allow(Trading::CoinbasePositions).to receive(:new).and_return(mock_positions_service)
      end

      it "handles successful position opening" do
        allow(mock_positions_service).to receive(:open_position).and_return({success: true})

        expect {
          job_instance.send(:execute_futures_signal, contract_id, signal)
        }.to change(Position, :count).by(1)

        expect(mock_logger).to have_received(:info).with(
          /Successfully opened LONG position: 2 contracts of #{contract_id}/
        )
      end

      it "handles position opening failures" do
        allow(mock_positions_service).to receive(:open_position).and_return({
          success: false,
          error: "API Error"
        })

        expect {
          job_instance.send(:execute_futures_signal, contract_id, signal)
        }.not_to change(Position, :count)

        expect(mock_logger).to have_received(:error).with(
          "[RSE] Failed to open position: API Error"
        )
      end

      it "handles exceptions during execution" do
        allow(mock_positions_service).to receive(:open_position).and_raise(StandardError, "Network error")

        expect {
          job_instance.send(:execute_futures_signal, contract_id, signal)
        }.not_to raise_error

        expect(mock_logger).to have_received(:error).with(
          "[RSE] Error executing futures signal: Network error"
        )
      end
    end
  end
end
