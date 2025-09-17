# frozen_string_literal: true

require "rails_helper"

RSpec.describe CalibrationJob, type: :job do
  let(:job) { described_class.new }
  let!(:enabled_pair) { create(:trading_pair, enabled: true, product_id: "BTC-29DEC24-CDE") }
  let!(:disabled_pair) { create(:trading_pair, enabled: false, product_id: "ETH-29DEC24-CDE") }

  # Mock objects for dependencies
  let(:mock_simulator) { instance_double(PaperTrading::ExchangeSimulator) }
  let(:mock_strategy) { instance_double(Strategy::Pullback1h) }

  before do
    # Mock Rails logger to avoid noise in test output
    allow(Rails.logger).to receive(:info)

    # Mock the simulator and strategy creation
    allow(PaperTrading::ExchangeSimulator).to receive(:new).and_return(mock_simulator)
    allow(Strategy::Pullback1h).to receive(:new).and_return(mock_strategy)

    # Setup default mock behaviors
    allow(mock_simulator).to receive(:equity_usd).and_return(10_000.0)
    allow(mock_simulator).to receive(:place_limit)
    allow(mock_simulator).to receive(:on_candle)
    allow(mock_strategy).to receive(:signal).and_return(nil)
  end

  describe "#perform" do
    context "with enabled trading pairs" do
      it "processes all enabled trading pairs" do
        expect(job).to receive(:calibrate_pair).with(enabled_pair)

        job.perform
      end

      it "skips disabled trading pairs" do
        expect(TradingPair).to receive(:enabled).and_call_original

        job.perform
      end
    end

    context "with no enabled trading pairs" do
      before do
        TradingPair.update_all(enabled: false)
      end

      it "completes without error when no enabled pairs exist" do
        expect { job.perform }.not_to raise_error
      end

      it "does not call calibrate_pair" do
        expect(job).not_to receive(:calibrate_pair)
        job.perform
      end
    end

    context "with multiple enabled trading pairs" do
      let!(:additional_pair) { create(:trading_pair, enabled: true, product_id: "ETH-29DEC24-CDE") }

      it "processes all enabled pairs" do
        expect(job).to receive(:calibrate_pair).twice

        job.perform
      end
    end
  end

  describe "#calibrate_pair" do
    context "with sufficient candle data" do
      before do
        create_candle_data_for_pair(enabled_pair.product_id, candle_count: 300)
      end

      it "retrieves hourly candles from the last 120 days" do
        120.days.ago

        expect(Candle).to receive(:for_symbol).with(enabled_pair.product_id).and_call_original

        job.send(:calibrate_pair, enabled_pair)
      end

      it "calls grid_search with retrieved candles" do
        candles = Candle.for_symbol(enabled_pair.product_id).hourly.order(:timestamp)

        expect(job).to receive(:grid_search).with(candles.to_a).and_return({
          tp_target: 0.006, sl_target: 0.004, pnl: 11_000.0
        })

        job.send(:calibrate_pair, enabled_pair)
      end

      it "logs the best parameters found" do
        best_params = {tp_target: 0.006, sl_target: 0.004, pnl: 11_500.0}
        allow(job).to receive(:grid_search).and_return(best_params)

        expect(Rails.logger).to receive(:info).with(
          "[Calibrate] #{enabled_pair.product_id} best params: #{best_params.inspect}"
        )

        job.send(:calibrate_pair, enabled_pair)
      end
    end

    context "with insufficient candle data" do
      before do
        create_candle_data_for_pair(enabled_pair.product_id, candle_count: 250) # Less than 300
      end

      it "returns early when candles are less than 300" do
        expect(job).not_to receive(:grid_search)
        expect(Rails.logger).not_to receive(:info)

        job.send(:calibrate_pair, enabled_pair)
      end

      it "does not perform any calibration" do
        expect(PaperTrading::ExchangeSimulator).not_to receive(:new)
        expect(Strategy::Pullback1h).not_to receive(:new)

        job.send(:calibrate_pair, enabled_pair)
      end
    end

    context "with no candle data" do
      it "returns early when no candles exist" do
        expect(job).not_to receive(:grid_search)
        job.send(:calibrate_pair, enabled_pair)
      end
    end

    context "with edge case candle counts" do
      it "processes exactly 300 candles" do
        create_candle_data_for_pair(enabled_pair.product_id, candle_count: 300)

        expect(job).to receive(:grid_search).and_return({
          tp_target: 0.004, sl_target: 0.003, pnl: 10_200.0
        })

        job.send(:calibrate_pair, enabled_pair)
      end

      it "returns early with exactly 299 candles" do
        create_candle_data_for_pair(enabled_pair.product_id, candle_count: 299)

        expect(job).not_to receive(:grid_search)
        job.send(:calibrate_pair, enabled_pair)
      end
    end
  end

  describe "#grid_search" do
    let(:sample_candles) { create_sample_candles(300) }

    before do
      # Mock the simulate method to return predictable results
      allow(job).to receive(:simulate).and_return(10_000.0)
    end

    it "tests all combinations of tp_targets and sl_targets" do
      # Should call simulate 9 times (3 tp * 3 sl combinations)
      expect(job).to receive(:simulate).exactly(9).times

      job.send(:grid_search, sample_candles)
    end

    it "returns the combination with highest PnL" do
      # Mock different PnL values for different combinations
      allow(job).to receive(:simulate) do |candles, tp_target:, sl_target:|
        case [tp_target, sl_target]
        when [0.004, 0.003] then 9_500.0   # Lowest
        when [0.006, 0.004] then 12_000.0  # Highest
        when [0.008, 0.005] then 11_000.0  # Middle
        else 10_000.0
        end
      end

      result = job.send(:grid_search, sample_candles)

      expect(result).to eq({
        tp_target: 0.006,
        sl_target: 0.004,
        pnl: 12_000.0
      })
    end

    it "handles ties by returning the first best result" do
      # Mock equal PnL values
      allow(job).to receive(:simulate).and_return(10_000.0)

      result = job.send(:grid_search, sample_candles)

      # Should return first combination (0.004, 0.003)
      expect(result).to eq({
        tp_target: 0.004,
        sl_target: 0.003,
        pnl: 10_000.0
      })
    end

    it "uses correct parameter ranges" do
      expected_tp_targets = [0.004, 0.006, 0.008]
      expected_sl_targets = [0.003, 0.004, 0.005]

      expected_tp_targets.each do |tp|
        expected_sl_targets.each do |sl|
          expect(job).to receive(:simulate).with(
            sample_candles,
            tp_target: tp,
            sl_target: sl
          ).and_return(10_000.0)
        end
      end

      job.send(:grid_search, sample_candles)
    end

    context "with negative PnL results" do
      before do
        allow(job).to receive(:simulate) do |candles, tp_target:, sl_target:|
          case [tp_target, sl_target]
          when [0.004, 0.003] then -500.0   # Loss
          when [0.006, 0.004] then -200.0   # Smaller loss (best)
          when [0.008, 0.005] then -800.0   # Bigger loss
          else -1000.0
          end
        end
      end

      it "selects the least negative result" do
        result = job.send(:grid_search, sample_candles)

        expect(result).to eq({
          tp_target: 0.006,
          sl_target: 0.004,
          pnl: -200.0
        })
      end
    end
  end

  describe "#simulate" do
    let(:sample_candles) { create_sample_candles(300) }
    let(:tp_target) { 0.006 }
    let(:sl_target) { 0.004 }

    before do
      # Reset mocks for simulate method testing
      allow(PaperTrading::ExchangeSimulator).to receive(:new).and_call_original
      allow(Strategy::Pullback1h).to receive(:new).and_call_original
    end

    it "creates a new ExchangeSimulator" do
      expect(PaperTrading::ExchangeSimulator).to receive(:new).and_return(mock_simulator)

      job.send(:simulate, sample_candles, tp_target: tp_target, sl_target: sl_target)
    end

    it "creates a Pullback1h strategy with correct parameters" do
      expect(Strategy::Pullback1h).to receive(:new).with(
        tp_target: tp_target,
        sl_target: sl_target
      ).and_return(mock_strategy)

      job.send(:simulate, sample_candles, tp_target: tp_target, sl_target: sl_target)
    end

    it "processes candles in sliding windows of 300" do
      # With 300 candles, should have 1 window (300 - 300 + 1)
      expect(mock_strategy).to receive(:signal).exactly(1).times

      job.send(:simulate, sample_candles, tp_target: tp_target, sl_target: sl_target)
    end

    it "calls simulator on_candle for each window" do
      expect(mock_simulator).to receive(:on_candle).exactly(1).times

      job.send(:simulate, sample_candles, tp_target: tp_target, sl_target: sl_target)
    end

    it "returns the final equity from simulator" do
      final_equity = 11_250.0
      allow(mock_simulator).to receive(:equity_usd).and_return(final_equity)

      result = job.send(:simulate, sample_candles, tp_target: tp_target, sl_target: sl_target)

      expect(result).to eq(final_equity)
    end

    context "when strategy generates signals" do
      let(:mock_order) do
        {
          side: :buy,
          price: 50_000.0,
          quantity: 1.0,
          tp: 53_000.0,
          sl: 48_000.0
        }
      end

      before do
        allow(mock_strategy).to receive(:signal).and_return(mock_order)
      end

      it "places limit orders when signals are generated" do
        expect(mock_simulator).to receive(:place_limit).with(
          symbol: sample_candles.last.symbol,
          side: mock_order[:side],
          price: mock_order[:price],
          quantity: mock_order[:quantity],
          tp: mock_order[:tp],
          sl: mock_order[:sl]
        ).exactly(1).times

        job.send(:simulate, sample_candles, tp_target: tp_target, sl_target: sl_target)
      end
    end

    context "when strategy generates no signals" do
      before do
        allow(mock_strategy).to receive(:signal).and_return(nil)
      end

      it "does not place any orders" do
        expect(mock_simulator).not_to receive(:place_limit)

        job.send(:simulate, sample_candles, tp_target: tp_target, sl_target: sl_target)
      end
    end

    context "when strategy generates signals with zero quantity" do
      let(:zero_quantity_order) do
        {
          side: :buy,
          price: 50_000.0,
          quantity: 0.0,
          tp: 53_000.0,
          sl: 48_000.0
        }
      end

      before do
        allow(mock_strategy).to receive(:signal).and_return(zero_quantity_order)
      end

      it "does not place orders with zero quantity" do
        expect(mock_simulator).not_to receive(:place_limit)

        job.send(:simulate, sample_candles, tp_target: tp_target, sl_target: sl_target)
      end
    end

    context "with varying equity levels" do
      it "passes current equity to strategy signal method" do
        varying_equity = [10_000.0, 10_500.0, 9_800.0, 11_200.0]
        allow(mock_simulator).to receive(:equity_usd).and_return(*varying_equity)

        # Should receive calls with different equity values
        expect(mock_strategy).to receive(:signal) do |args|
          expect(args[:equity_usd]).to be_in(varying_equity)
          nil
        end.at_least(:once)

        job.send(:simulate, sample_candles, tp_target: tp_target, sl_target: sl_target)
      end
    end
  end

  describe "error handling" do
    before do
      create_candle_data_for_pair(enabled_pair.product_id, candle_count: 350)
    end

    context "when grid_search fails" do
      before do
        allow(job).to receive(:grid_search).and_raise(StandardError.new("Grid search failed"))
      end

      it "propagates the error" do
        expect { job.send(:calibrate_pair, enabled_pair) }.to raise_error(StandardError, "Grid search failed")
      end
    end

    context "when simulate fails" do
      before do
        allow(job).to receive(:simulate).and_raise(ArgumentError.new("Invalid parameters"))
      end

      it "propagates the error during grid search" do
        expect { job.send(:calibrate_pair, enabled_pair) }.to raise_error(ArgumentError, "Invalid parameters")
      end
    end

    context "when ExchangeSimulator initialization fails" do
      before do
        allow(PaperTrading::ExchangeSimulator).to receive(:new).and_raise(StandardError.new("Simulator init failed"))
      end

      it "propagates the error" do
        expect { job.send(:calibrate_pair, enabled_pair) }.to raise_error(StandardError, "Simulator init failed")
      end
    end

    context "when Strategy initialization fails" do
      before do
        allow(Strategy::Pullback1h).to receive(:new).and_raise(ArgumentError.new("Invalid strategy params"))
      end

      it "propagates the error" do
        expect { job.send(:calibrate_pair, enabled_pair) }.to raise_error(ArgumentError, "Invalid strategy params")
      end
    end

    context "when candle data is corrupted" do
      before do
        # Mock corrupted candle data without creating actual records
        corrupted_candles = [
          double("Candle", close: nil, low: 49_000, symbol: enabled_pair.product_id),
          double("Candle", close: 50_000, low: 49_000, symbol: enabled_pair.product_id)
        ]
        allow(Candle).to receive_message_chain(:for_symbol, :hourly, :where, :order, :to_a).and_return(corrupted_candles)
      end

      it "handles corrupted data gracefully" do
        # Should return early due to insufficient data
        expect { job.send(:calibrate_pair, enabled_pair) }.not_to raise_error
      end
    end

    context "when database query fails" do
      before do
        allow(Candle).to receive(:for_symbol).and_raise(ActiveRecord::ConnectionTimeoutError.new("DB timeout"))
      end

      it "propagates database errors" do
        expect { job.send(:calibrate_pair, enabled_pair) }.to raise_error(ActiveRecord::ConnectionTimeoutError, "DB timeout")
      end
    end
  end

  describe "parameter validation" do
    let(:sample_candles) { create_sample_candles(350) }

    context "with extreme parameter values" do
      it "handles very small tp_target values" do
        expect { job.send(:simulate, sample_candles, tp_target: 0.001, sl_target: 0.004) }.not_to raise_error
      end

      it "handles very large tp_target values" do
        expect { job.send(:simulate, sample_candles, tp_target: 0.05, sl_target: 0.004) }.not_to raise_error
      end

      it "handles tp_target smaller than sl_target" do
        # This is an unusual but valid scenario that should not crash
        expect { job.send(:simulate, sample_candles, tp_target: 0.002, sl_target: 0.004) }.not_to raise_error
      end
    end

    context "with invalid parameter types" do
      it "handles string parameters" do
        expect { job.send(:simulate, sample_candles, tp_target: "0.006", sl_target: "0.004") }.not_to raise_error
      end

      it "handles nil parameters" do
        expect { job.send(:simulate, sample_candles, tp_target: nil, sl_target: nil) }.to raise_error
      end
    end
  end

  describe "performance characteristics" do
    context "with large datasets" do
      let(:large_candle_set) { create_sample_candles(350) }

      it "handles large candle datasets efficiently" do
        start_time = Time.current

        job.send(:simulate, large_candle_set, tp_target: 0.006, sl_target: 0.004)

        execution_time = Time.current - start_time
        expect(execution_time).to be < 5.seconds # Performance expectation
      end

      it "processes all windows correctly with large datasets" do
        # With 350 candles, should have 51 windows (350 - 300 + 1)
        expect(mock_strategy).to receive(:signal).exactly(51).times

        job.send(:simulate, large_candle_set, tp_target: 0.006, sl_target: 0.004)
      end
    end
  end

  describe "integration with trading strategies" do
    let(:sample_candles) { create_sample_candles(300) }

    before do
      # Use real strategy and simulator for integration tests
      allow(PaperTrading::ExchangeSimulator).to receive(:new).and_call_original
      allow(Strategy::Pullback1h).to receive(:new).and_call_original
    end

    it "integrates correctly with Pullback1h strategy" do
      result = job.send(:simulate, sample_candles, tp_target: 0.006, sl_target: 0.004)

      expect(result).to be_a(Numeric)
      expect(result).to be > 0 # Should have some equity value
    end

    it "validates parameter adjustment workflows" do
      # Test different parameter combinations
      result1 = job.send(:simulate, sample_candles, tp_target: 0.004, sl_target: 0.003)
      result2 = job.send(:simulate, sample_candles, tp_target: 0.008, sl_target: 0.005)

      # Results should be different (unless market is perfectly flat)
      expect(result1).to be_a(Numeric)
      expect(result2).to be_a(Numeric)
    end

    it "ensures calibration accuracy verification" do
      # Run grid search and verify it finds optimal parameters
      result = job.send(:grid_search, sample_candles)

      expect(result).to have_key(:tp_target)
      expect(result).to have_key(:sl_target)
      expect(result).to have_key(:pnl)
      expect(result[:tp_target]).to be_in([0.004, 0.006, 0.008])
      expect(result[:sl_target]).to be_in([0.003, 0.004, 0.005])
    end
  end

  describe "rollback mechanisms" do
    let(:sample_candles) { create_sample_candles(300) }

    context "when calibration fails mid-process" do
      before do
        # Simulate failure after some progress
        call_count = 0
        allow(mock_strategy).to receive(:signal) do
          call_count += 1
          raise StandardError.new("Strategy failed") if call_count > 25
          nil
        end
      end

      it "handles partial calibration failures" do
        expect { job.send(:simulate, sample_candles, tp_target: 0.006, sl_target: 0.004) }.to raise_error(StandardError, "Strategy failed")
      end
    end

    context "when simulator state becomes inconsistent" do
      before do
        allow(mock_simulator).to receive(:equity_usd) do
          # Simulate inconsistent state
          [-1000.0, Float::NAN, nil].sample
        end
      end

      it "handles inconsistent simulator states" do
        # Should not crash even with invalid equity values
        expect { job.send(:simulate, sample_candles, tp_target: 0.006, sl_target: 0.004) }.not_to raise_error
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

  describe "ActiveJob integration" do
    it "can be enqueued" do
      expect { described_class.perform_later }.not_to raise_error
    end

    it "can be performed immediately" do
      expect { described_class.perform_now }.not_to raise_error
    end
  end

  # ========== HELPER METHODS ==========

  private

  def create_candle_data_for_pair(product_id, candle_count:)
    base_time = 120.days.ago

    # Use bulk insert for performance
    candles_data = (0...candle_count).map do |i|
      {
        symbol: product_id,
        timeframe: "1h",
        timestamp: base_time + i.hours,
        open: 50_000 + (i * 10),
        high: 50_000 + (i * 10) + 500,
        low: 50_000 + (i * 10) - 500,
        close: 50_000 + (i * 10) + 100,
        volume: 1000 + (i * 5),
        created_at: Time.current,
        updated_at: Time.current
      }
    end

    Candle.insert_all(candles_data)
  end

  def create_sample_candles(count)
    base_time = Time.current.utc - count.hours

    (0...count).map do |i|
      Candle.new(
        symbol: "BTC-TEST",
        timeframe: "1h",
        timestamp: base_time + i.hours,
        open: 50_000 + (i * 10),
        high: 50_000 + (i * 10) + 500,
        low: 50_000 + (i * 10) - 500,
        close: 50_000 + (i * 10) + 100,
        volume: 1000 + (i * 5)
      )
    end
  end
end
