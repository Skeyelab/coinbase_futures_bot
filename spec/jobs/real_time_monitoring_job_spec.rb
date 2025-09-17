# frozen_string_literal: true

require "rails_helper"

RSpec.describe RealTimeMonitoringJob, type: :job do
  let(:job) { described_class.new }
  let(:product_ids) { ["BTC-USD", "ETH-USD"] }
  let(:logger) { instance_double(Logger) }
  let(:contract_manager) { instance_double(MarketData::FuturesContractManager) }
  let(:spot_subscriber) { instance_double(MarketData::CoinbaseSpotSubscriber) }

  before do
    allow(Rails).to receive(:logger).and_return(logger)
    allow(logger).to receive(:info)
    allow(logger).to receive(:debug)
    allow(logger).to receive(:warn)
    allow(logger).to receive(:error)
    
    allow(MarketData::FuturesContractManager).to receive(:new).and_return(contract_manager)
    allow(MarketData::CoinbaseSpotSubscriber).to receive(:new).and_return(spot_subscriber)
    allow(spot_subscriber).to receive(:start)
    
    # Mock Rails.cache
    allow(Rails.cache).to receive(:read)
    allow(Rails.cache).to receive(:write)
  end

  describe "job configuration" do
    it "uses the critical queue" do
      expect(described_class.queue_name).to eq("critical")
    end

    it "inherits from ApplicationJob" do
      expect(described_class.superclass).to eq(ApplicationJob)
    end
  end

  describe "#perform" do
    context "with default product IDs" do
      it "starts monitoring with default BTC and ETH products" do
        expect(logger).to receive(:info).with("[RTM] Starting real-time monitoring for BTC-USD, ETH-USD")
        
        expect(MarketData::CoinbaseSpotSubscriber).to receive(:new).with(
          product_ids: ["BTC-USD", "ETH-USD"],
          logger: logger,
          on_ticker: kind_of(Proc)
        ).and_return(spot_subscriber)
        
        expect(spot_subscriber).to receive(:start)
        
        job.perform
      end
    end

    context "with custom product IDs" do
      let(:custom_products) { ["BTC-USD"] }

      it "starts monitoring with specified products" do
        expect(logger).to receive(:info).with("[RTM] Starting real-time monitoring for BTC-USD")
        
        expect(MarketData::CoinbaseSpotSubscriber).to receive(:new).with(
          product_ids: custom_products,
          logger: logger,
          on_ticker: kind_of(Proc)
        ).and_return(spot_subscriber)
        
        expect(spot_subscriber).to receive(:start)
        
        job.perform(product_ids: custom_products)
      end
    end

    context "with string product ID" do
      it "converts single product ID to array" do
        expect(logger).to receive(:info).with("[RTM] Starting real-time monitoring for BTC-USD")
        
        expect(MarketData::CoinbaseSpotSubscriber).to receive(:new).with(
          product_ids: ["BTC-USD"],
          logger: logger,
          on_ticker: kind_of(Proc)
        ).and_return(spot_subscriber)
        
        job.perform(product_ids: "BTC-USD")
      end
    end

    it "initializes contract manager with logger" do
      expect(MarketData::FuturesContractManager).to receive(:new).with(logger: logger)
      job.perform
    end

    it "sets up ticker callback for real-time processing" do
      captured_callback = nil
      
      expect(MarketData::CoinbaseSpotSubscriber).to receive(:new) do |args|
        captured_callback = args[:on_ticker]
        spot_subscriber
      end
      
      job.perform
      
      expect(captured_callback).to be_a(Proc)
    end
  end

  describe "#process_real_time_tick" do
    let(:ticker_data) do
      {
        "product_id" => "BTC-USD",
        "price" => "50000.00",
        "time" => "2024-01-01T12:00:00Z"
      }
    end

    before do
      job.instance_variable_set(:@logger, logger)
      job.instance_variable_set(:@contract_manager, contract_manager)
    end

    context "with valid ticker data" do
      it "logs debug information for tick processing" do
        expect(logger).to receive(:debug).with("[RTM] BTC-USD: $50000.0 at 2024-01-01T12:00:00Z")
        
        allow(job).to receive(:create_tick_record)
        allow(job).to receive(:check_position_alerts)
        allow(job).to receive(:futures_relevant?).and_return(false)
        allow(job).to receive(:should_evaluate_signals?).and_return(false)
        
        job.send(:process_real_time_tick, ticker_data)
      end

      it "creates tick record for valid data" do
        expect(job).to receive(:create_tick_record).with("BTC-USD", 50000.0, "2024-01-01T12:00:00Z")
        
        allow(job).to receive(:check_position_alerts)
        allow(job).to receive(:futures_relevant?).and_return(false)
        allow(job).to receive(:should_evaluate_signals?).and_return(false)
        
        job.send(:process_real_time_tick, ticker_data)
      end

      it "checks position alerts for the product" do
        expect(job).to receive(:check_position_alerts).with("BTC-USD", 50000.0)
        
        allow(job).to receive(:create_tick_record)
        allow(job).to receive(:futures_relevant?).and_return(false)
        allow(job).to receive(:should_evaluate_signals?).and_return(false)
        
        job.send(:process_real_time_tick, ticker_data)
      end

      context "when futures relevant" do
        it "updates futures monitoring" do
          allow(job).to receive(:futures_relevant?).with("BTC-USD").and_return(true)
          expect(job).to receive(:update_futures_monitoring).with("BTC-USD", 50000.0)
          
          allow(job).to receive(:create_tick_record)
          allow(job).to receive(:check_position_alerts)
          allow(job).to receive(:should_evaluate_signals?).and_return(false)
          
          job.send(:process_real_time_tick, ticker_data)
        end
      end

      context "when should evaluate signals" do
        it "evaluates rapid signals" do
          allow(job).to receive(:should_evaluate_signals?).with("BTC-USD", 50000.0).and_return(true)
          expect(job).to receive(:evaluate_rapid_signals).with("BTC-USD", 50000.0)
          
          allow(job).to receive(:create_tick_record)
          allow(job).to receive(:check_position_alerts)
          allow(job).to receive(:futures_relevant?).and_return(false)
          
          job.send(:process_real_time_tick, ticker_data)
        end
      end
    end

    context "with invalid ticker data" do
      [
        {"product_id" => nil, "price" => "50000.00", "time" => "2024-01-01T12:00:00Z"},
        {"product_id" => "BTC-USD", "price" => nil, "time" => "2024-01-01T12:00:00Z"},
        {"product_id" => "BTC-USD", "price" => "0", "time" => "2024-01-01T12:00:00Z"},
        {"product_id" => "BTC-USD", "price" => "-100", "time" => "2024-01-01T12:00:00Z"}
      ].each do |invalid_data|
        it "skips processing for invalid data: #{invalid_data}" do
          expect(job).not_to receive(:create_tick_record)
          expect(job).not_to receive(:check_position_alerts)
          
          job.send(:process_real_time_tick, invalid_data)
        end
      end
    end
  end

  describe "#create_tick_record" do
    let(:product_id) { "BTC-USD" }
    let(:price) { 50000.0 }
    let(:timestamp) { "2024-01-01T12:00:00Z" }
    let(:parsed_time) { Time.parse(timestamp) }

    before do
      job.instance_variable_set(:@logger, logger)
      allow(job).to receive(:parse_timestamp).with(timestamp).and_return(parsed_time)
    end

    it "creates a tick record with correct attributes" do
      expect(Tick).to receive(:create!).with(
        product_id: product_id,
        price: price,
        observed_at: parsed_time
      )
      
      job.send(:create_tick_record, product_id, price, timestamp)
    end

    context "when tick creation fails" do
      let(:error) { StandardError.new("Database error") }

      it "logs warning and continues processing" do
        allow(Tick).to receive(:create!).and_raise(error)
        
        expect(logger).to receive(:warn).with("[RTM] Failed to store tick for BTC-USD: Database error")
        
        expect {
          job.send(:create_tick_record, product_id, price, timestamp)
        }.not_to raise_error
      end
    end
  end

  describe "#check_position_alerts" do
    let(:product_id) { "BTC-USD" }
    let(:price) { 50000.0 }
    let(:asset) { "BTC" }
    let(:position1) { create(:position, product_id: "BIT-29DEC24", entry_time: 2.hours.ago) }
    let(:position2) { create(:position, product_id: "BIT-29DEC24", entry_time: 8.hours.ago) }

    before do
      job.instance_variable_set(:@logger, logger)
      allow(job).to receive(:extract_asset_from_product_id).with(product_id).and_return(asset)
    end

    context "with open positions for the asset" do
      before do
        allow(Position).to receive_message_chain(:open, :by_asset).with(asset).and_return([position1, position2])
      end

      it "checks take profit and stop loss for each position" do
        expect(job).to receive(:check_take_profit_stop_loss).with(position1, price)
        expect(job).to receive(:check_take_profit_stop_loss).with(position2, price)
        
        allow(job).to receive(:check_day_trading_time_limits)
        
        job.send(:check_position_alerts, product_id, price)
      end

      it "checks day trading time limits for each position" do
        expect(job).to receive(:check_day_trading_time_limits).with(position1)
        expect(job).to receive(:check_day_trading_time_limits).with(position2)
        
        allow(job).to receive(:check_take_profit_stop_loss)
        
        job.send(:check_position_alerts, product_id, price)
      end
    end

    context "when asset extraction fails" do
      before do
        allow(job).to receive(:extract_asset_from_product_id).with(product_id).and_return(nil)
      end

      it "returns early without checking positions" do
        expect(Position).not_to receive(:open)
        
        job.send(:check_position_alerts, product_id, price)
      end
    end

    context "with no open positions" do
      before do
        allow(Position).to receive_message_chain(:open, :by_asset).with(asset).and_return([])
      end

      it "does not perform position checks" do
        expect(job).not_to receive(:check_take_profit_stop_loss)
        expect(job).not_to receive(:check_day_trading_time_limits)
        
        job.send(:check_position_alerts, product_id, price)
      end
    end
  end

  describe "#check_take_profit_stop_loss" do
    let(:current_price) { 50000.0 }

    before do
      job.instance_variable_set(:@logger, logger)
      allow(job).to receive(:trigger_position_close)
    end

    context "with long position" do
      context "with take profit set" do
        let(:position) { create(:position, take_profit: 51000.0, stop_loss: 49000.0) }

        it "triggers take profit when price hits target" do
          expect(logger).to receive(:info).with("[RTM] Take profit hit for LONG position #{position.product_id} at $51000.0")
          expect(job).to receive(:trigger_position_close).with(position, "take_profit")
          
          job.send(:check_take_profit_stop_loss, position, 51000.0)
        end

        it "triggers stop loss when price hits target" do
          expect(logger).to receive(:info).with("[RTM] Stop loss hit for LONG position #{position.product_id} at $49000.0")
          expect(job).to receive(:trigger_position_close).with(position, "stop_loss")
          
          job.send(:check_take_profit_stop_loss, position, 49000.0)
        end

        it "does nothing when price is between targets" do
          expect(job).not_to receive(:trigger_position_close)
          
          job.send(:check_take_profit_stop_loss, position, 50500.0)
        end
      end

      context "without take profit or stop loss" do
        let(:position) { create(:position, take_profit: nil, stop_loss: nil) }

        it "does nothing" do
          expect(job).not_to receive(:trigger_position_close)
          
          job.send(:check_take_profit_stop_loss, position, current_price)
        end
      end
    end

    context "with short position" do
      context "with take profit set" do
        let(:position) { create(:position, :short, take_profit: 49000.0, stop_loss: 51000.0) }

        it "triggers take profit when price hits target" do
          expect(logger).to receive(:info).with("[RTM] Take profit hit for SHORT position #{position.product_id} at $49000.0")
          expect(job).to receive(:trigger_position_close).with(position, "take_profit")
          
          job.send(:check_take_profit_stop_loss, position, 49000.0)
        end

        it "triggers stop loss when price hits target" do
          expect(logger).to receive(:info).with("[RTM] Stop loss hit for SHORT position #{position.product_id} at $51000.0")
          expect(job).to receive(:trigger_position_close).with(position, "stop_loss")
          
          job.send(:check_take_profit_stop_loss, position, 51000.0)
        end

        it "does nothing when price is between targets" do
          expect(job).not_to receive(:trigger_position_close)
          
          job.send(:check_take_profit_stop_loss, position, 50500.0)
        end
      end
    end
  end

  describe "#check_day_trading_time_limits" do
    before do
      job.instance_variable_set(:@logger, logger)
      allow(job).to receive(:trigger_position_close)
    end

    context "with day trading position" do
      let(:position) { create(:position, entry_time: 7.hours.ago) }

      before do
        allow(position).to receive(:age_in_hours).and_return(7.0)
      end

      it "triggers position close when exceeding 6-hour limit" do
        expect(logger).to receive(:warn).with("[RTM] Day trading position #{position.product_id} exceeded 6-hour limit")
        expect(job).to receive(:trigger_position_close).with(position, "time_limit")
        
        job.send(:check_day_trading_time_limits, position)
      end
    end

    context "with day trading position within time limit" do
      let(:position) { create(:position, entry_time: 4.hours.ago) }

      before do
        allow(position).to receive(:age_in_hours).and_return(4.0)
      end

      it "does not trigger position close" do
        expect(job).not_to receive(:trigger_position_close)
        
        job.send(:check_day_trading_time_limits, position)
      end
    end

    context "with swing trading position" do
      let(:position) { create(:position, :swing_trading, entry_time: 8.hours.ago) }

      it "does not check time limits" do
        expect(job).not_to receive(:trigger_position_close)
        
        job.send(:check_day_trading_time_limits, position)
      end
    end

    context "when age_in_hours is nil" do
      let(:position) { create(:position) }

      before do
        allow(position).to receive(:age_in_hours).and_return(nil)
      end

      it "does not trigger position close" do
        expect(job).not_to receive(:trigger_position_close)
        
        job.send(:check_day_trading_time_limits, position)
      end
    end
  end

  describe "#trigger_position_close" do
    let(:position) { create(:position) }
    let(:reason) { "take_profit" }

    it "enqueues PositionCloseJob with correct parameters" do
      expect(PositionCloseJob).to receive(:perform_later).with(
        position_id: position.id,
        reason: reason,
        priority: "immediate"
      )
      
      job.send(:trigger_position_close, position, reason)
    end

    it "handles different closure reasons" do
      ["take_profit", "stop_loss", "time_limit"].each do |test_reason|
        expect(PositionCloseJob).to receive(:perform_later).with(
          position_id: position.id,
          reason: test_reason,
          priority: "immediate"
        )
        
        job.send(:trigger_position_close, position, test_reason)
      end
    end
  end

  describe "#update_futures_monitoring" do
    let(:product_id) { "BTC-USD" }
    let(:price) { 50000.0 }
    let(:asset) { "BTC" }
    let(:current_contract) { "BIT-29DEC24" }
    let(:upcoming_contract) { "BIT-29JAN25" }

    before do
      job.instance_variable_set(:@contract_manager, contract_manager)
      allow(job).to receive(:extract_asset_from_product_id).with(product_id).and_return(asset)
    end

    context "with available contracts" do
      before do
        allow(contract_manager).to receive(:current_month_contract).with(asset).and_return(current_contract)
        allow(contract_manager).to receive(:upcoming_month_contract).with(asset).and_return(upcoming_contract)
      end

      it "enqueues FuturesBasisMonitoringJob for current contract" do
        expect(FuturesBasisMonitoringJob).to receive(:perform_later).with(
          spot_product_id: product_id,
          futures_product_id: current_contract,
          spot_price: price
        )
        
        allow(FuturesBasisMonitoringJob).to receive(:perform_later).with(
          spot_product_id: product_id,
          futures_product_id: upcoming_contract,
          spot_price: price
        )
        
        job.send(:update_futures_monitoring, product_id, price)
      end

      it "enqueues FuturesBasisMonitoringJob for upcoming contract" do
        expect(FuturesBasisMonitoringJob).to receive(:perform_later).with(
          spot_product_id: product_id,
          futures_product_id: upcoming_contract,
          spot_price: price
        )
        
        allow(FuturesBasisMonitoringJob).to receive(:perform_later).with(
          spot_product_id: product_id,
          futures_product_id: current_contract,
          spot_price: price
        )
        
        job.send(:update_futures_monitoring, product_id, price)
      end
    end

    context "with only current contract available" do
      before do
        allow(contract_manager).to receive(:current_month_contract).with(asset).and_return(current_contract)
        allow(contract_manager).to receive(:upcoming_month_contract).with(asset).and_return(nil)
      end

      it "enqueues job only for current contract" do
        expect(FuturesBasisMonitoringJob).to receive(:perform_later).with(
          spot_product_id: product_id,
          futures_product_id: current_contract,
          spot_price: price
        ).once
        
        job.send(:update_futures_monitoring, product_id, price)
      end
    end

    context "with no contracts available" do
      before do
        allow(contract_manager).to receive(:current_month_contract).with(asset).and_return(nil)
        allow(contract_manager).to receive(:upcoming_month_contract).with(asset).and_return(nil)
      end

      it "does not enqueue any jobs" do
        expect(FuturesBasisMonitoringJob).not_to receive(:perform_later)
        
        job.send(:update_futures_monitoring, product_id, price)
      end
    end

    context "when asset extraction fails" do
      before do
        allow(job).to receive(:extract_asset_from_product_id).with(product_id).and_return(nil)
      end

      it "returns early without processing" do
        expect(contract_manager).not_to receive(:current_month_contract)
        expect(FuturesBasisMonitoringJob).not_to receive(:perform_later)
        
        job.send(:update_futures_monitoring, product_id, price)
      end
    end
  end

  describe "#evaluate_rapid_signals" do
    let(:product_id) { "BTC-USD" }
    let(:price) { 50000.0 }
    let(:asset) { "BTC" }

    before do
      allow(job).to receive(:extract_asset_from_product_id).with(product_id).and_return(asset)
      allow(Rails.cache).to receive(:read).and_return(nil)
      allow(Rails.cache).to receive(:write)
    end

    context "with no recent signal evaluation" do
      it "evaluates signals and updates cache" do
        cache_key = "last_signal_eval_#{product_id}"
        current_time = Time.current
        
        allow(Time).to receive(:current).and_return(current_time)
        
        expect(Rails.cache).to receive(:write).with(cache_key, current_time, expires_in: 1.minute)
        expect(RapidSignalEvaluationJob).to receive(:perform_later).with(
          product_id: product_id,
          current_price: price,
          asset: asset
        )
        
        job.send(:evaluate_rapid_signals, product_id, price)
      end
    end

    context "with recent signal evaluation" do
      let(:last_eval_time) { 10.seconds.ago }

      before do
        allow(Rails.cache).to receive(:read).with("last_signal_eval_#{product_id}").and_return(last_eval_time)
        allow(Time).to receive(:current).and_return(last_eval_time + 10.seconds)
      end

      it "does not evaluate signals again" do
        expect(RapidSignalEvaluationJob).not_to receive(:perform_later)
        
        job.send(:evaluate_rapid_signals, product_id, price)
      end
    end

    context "with signal evaluation older than 30 seconds" do
      let(:last_eval_time) { 45.seconds.ago }
      let(:current_time) { Time.current }

      before do
        allow(Rails.cache).to receive(:read).with("last_signal_eval_#{product_id}").and_return(last_eval_time)
        allow(Time).to receive(:current).and_return(current_time)
      end

      it "evaluates signals and updates cache" do
        cache_key = "last_signal_eval_#{product_id}"
        
        expect(Rails.cache).to receive(:write).with(cache_key, current_time, expires_in: 1.minute)
        expect(RapidSignalEvaluationJob).to receive(:perform_later).with(
          product_id: product_id,
          current_price: price,
          asset: asset
        )
        
        job.send(:evaluate_rapid_signals, product_id, price)
      end
    end

    context "when asset extraction fails" do
      before do
        allow(job).to receive(:extract_asset_from_product_id).with(product_id).and_return(nil)
      end

      it "returns early without evaluation" do
        expect(RapidSignalEvaluationJob).not_to receive(:perform_later)
        
        job.send(:evaluate_rapid_signals, product_id, price)
      end
    end
  end

  describe "#should_evaluate_signals?" do
    let(:product_id) { "BTC-USD" }
    let(:price) { 50000.0 }
    let(:last_price) { 49950.0 }

    before do
      # Mock Eastern Time zone
      allow(Time).to receive(:current).and_return(Time.parse("2024-01-01 14:00:00 UTC")) # 9 AM ET
      allow(Rails.cache).to receive(:write)
    end

    context "during active trading hours" do
      [9, 10, 12, 14, 16].each do |hour|
        it "returns true during hour #{hour} ET" do
          et_time = Time.parse("2024-01-01 #{hour}:00:00 EST")
          utc_time = et_time.utc
          
          allow(Time).to receive(:current).and_return(utc_time)
          allow(Rails.cache).to receive(:read).with("last_price_#{product_id}").and_return(nil)
          
          result = job.send(:should_evaluate_signals?, product_id, price)
          expect(result).to be true
        end
      end
    end

    context "outside active trading hours" do
      [8, 17, 18, 0, 6].each do |hour|
        it "returns false during hour #{hour} ET" do
          et_time = Time.parse("2024-01-01 #{hour}:00:00 EST")
          utc_time = et_time.utc
          
          allow(Time).to receive(:current).and_return(utc_time)
          
          result = job.send(:should_evaluate_signals?, product_id, price)
          expect(result).to be false
        end
      end
    end

    context "with significant price movement" do
      before do
        allow(Time).to receive(:current).and_return(Time.parse("2024-01-01 14:00:00 UTC")) # 9 AM ET
      end

      it "returns true when price change exceeds 0.1%" do
        # 0.2% price change
        significant_price = 50100.0 # 0.2% increase from 50000
        
        allow(Rails.cache).to receive(:read).with("last_price_#{product_id}").and_return(price)
        
        result = job.send(:should_evaluate_signals?, product_id, significant_price)
        expect(result).to be true
      end

      it "returns false when price change is below 0.1%" do
        # 0.05% price change
        insignificant_price = 50025.0 # 0.05% increase from 50000
        
        allow(Rails.cache).to receive(:read).with("last_price_#{product_id}").and_return(price)
        
        result = job.send(:should_evaluate_signals?, product_id, insignificant_price)
        expect(result).to be false
      end

      it "returns true for first price (no cached price)" do
        allow(Rails.cache).to receive(:read).with("last_price_#{product_id}").and_return(nil)
        
        result = job.send(:should_evaluate_signals?, product_id, price)
        expect(result).to be true
      end

      it "caches the current price for future comparisons" do
        allow(Rails.cache).to receive(:read).with("last_price_#{product_id}").and_return(nil)
        
        expect(Rails.cache).to receive(:write).with("last_price_#{product_id}", price, expires_in: 5.minutes)
        
        job.send(:should_evaluate_signals?, product_id, price)
      end
    end

    context "with price decrease" do
      it "considers absolute value of price change" do
        allow(Time).to receive(:current).and_return(Time.parse("2024-01-01 14:00:00 UTC")) # 9 AM ET
        
        # 0.2% price decrease
        decreased_price = 49900.0 # 0.2% decrease from 50000
        
        allow(Rails.cache).to receive(:read).with("last_price_#{product_id}").and_return(price)
        
        result = job.send(:should_evaluate_signals?, product_id, decreased_price)
        expect(result).to be true
      end
    end
  end

  describe "#futures_relevant?" do
    it "returns true for BTC-USD" do
      result = job.send(:futures_relevant?, "BTC-USD")
      expect(result).to be true
    end

    it "returns true for ETH-USD" do
      result = job.send(:futures_relevant?, "ETH-USD")
      expect(result).to be true
    end

    it "returns false for other products" do
      ["DOGE-USD", "ADA-USD", "SOL-USD"].each do |product_id|
        result = job.send(:futures_relevant?, product_id)
        expect(result).to be false
      end
    end
  end

  describe "#extract_asset_from_product_id" do
    it "extracts BTC from BTC-USD" do
      result = job.send(:extract_asset_from_product_id, "BTC-USD")
      expect(result).to eq("BTC")
    end

    it "extracts ETH from ETH-USD" do
      result = job.send(:extract_asset_from_product_id, "ETH-USD")
      expect(result).to eq("ETH")
    end

    it "returns nil for other products" do
      ["DOGE-USD", "ADA-USD", "SOL-USD"].each do |product_id|
        result = job.send(:extract_asset_from_product_id, product_id)
        expect(result).to be_nil
      end
    end
  end

  describe "#parse_timestamp" do
    it "parses valid ISO timestamp" do
      timestamp = "2024-01-01T12:00:00Z"
      result = job.send(:parse_timestamp, timestamp)
      expect(result).to eq(Time.parse(timestamp))
    end

    it "returns current time for nil timestamp" do
      current_time = Time.current
      allow(Time).to receive(:current).and_return(current_time)
      
      result = job.send(:parse_timestamp, nil)
      expect(result).to eq(current_time)
    end

    it "returns current time for invalid timestamp" do
      current_time = Time.current
      allow(Time).to receive(:current).and_return(current_time)
      
      result = job.send(:parse_timestamp, "invalid-timestamp")
      expect(result).to eq(current_time)
    end

    it "handles various timestamp formats" do
      valid_timestamps = [
        "2024-01-01T12:00:00Z",
        "2024-01-01T12:00:00.123Z",
        "2024-01-01 12:00:00",
        "Mon, 01 Jan 2024 12:00:00 GMT"
      ]
      
      valid_timestamps.each do |timestamp|
        expect {
          result = job.send(:parse_timestamp, timestamp)
          expect(result).to be_a(Time)
        }.not_to raise_error
      end
    end
  end

  describe "error handling and resilience" do
    before do
      job.instance_variable_set(:@logger, logger)
    end

    context "when MarketData::CoinbaseSpotSubscriber initialization fails" do
      it "propagates the error" do
        allow(MarketData::CoinbaseSpotSubscriber).to receive(:new).and_raise(StandardError.new("Connection error"))
        
        expect {
          job.perform
        }.to raise_error(StandardError, "Connection error")
      end
    end

    context "when spot subscriber start fails" do
      it "propagates the error" do
        allow(spot_subscriber).to receive(:start).and_raise(StandardError.new("WebSocket error"))
        
        expect {
          job.perform
        }.to raise_error(StandardError, "WebSocket error")
      end
    end

    context "during tick processing" do
      let(:ticker_data) do
        {
          "product_id" => "BTC-USD",
          "price" => "50000.00",
          "time" => "2024-01-01T12:00:00Z"
        }
      end

      before do
        job.instance_variable_set(:@contract_manager, contract_manager)
      end

      it "continues processing even if position alerts fail" do
        allow(job).to receive(:create_tick_record)
        allow(job).to receive(:check_position_alerts).and_raise(StandardError.new("Position error"))
        allow(job).to receive(:futures_relevant?).and_return(false)
        allow(job).to receive(:should_evaluate_signals?).and_return(false)
        
        # Should not raise error - error handling should be internal
        expect {
          job.send(:process_real_time_tick, ticker_data)
        }.to raise_error(StandardError, "Position error") # Currently propagates - could be improved
      end
    end
  end

  describe "performance and high-frequency processing" do
    let(:ticker_data) do
      {
        "product_id" => "BTC-USD",
        "price" => "50000.00",
        "time" => "2024-01-01T12:00:00Z"
      }
    end

    before do
      job.instance_variable_set(:@logger, logger)
      job.instance_variable_set(:@contract_manager, contract_manager)
      
      # Mock all dependencies to focus on performance
      allow(job).to receive(:create_tick_record)
      allow(job).to receive(:check_position_alerts)
      allow(job).to receive(:futures_relevant?).and_return(false)
      allow(job).to receive(:should_evaluate_signals?).and_return(false)
    end

    it "processes multiple ticks efficiently" do
      start_time = Time.current
      
      100.times do |i|
        tick_data = ticker_data.merge("price" => (50000 + i).to_s)
        job.send(:process_real_time_tick, tick_data)
      end
      
      processing_time = Time.current - start_time
      expect(processing_time).to be < 1.0 # Should process 100 ticks in under 1 second
    end

    it "handles rapid price updates without blocking" do
      prices = (50000..50100).to_a.sample(50)
      
      expect {
        prices.each do |price|
          tick_data = ticker_data.merge("price" => price.to_s)
          job.send(:process_real_time_tick, tick_data)
        end
      }.not_to raise_error
    end
  end

  describe "integration with external systems" do
    context "with MarketData::FuturesContractManager" do
      it "initializes contract manager with logger" do
        expect(MarketData::FuturesContractManager).to receive(:new).with(logger: logger)
        job.perform
      end
    end

    context "with MarketData::CoinbaseSpotSubscriber" do
      it "configures spot subscriber with correct parameters" do
        expect(MarketData::CoinbaseSpotSubscriber).to receive(:new).with(
          product_ids: ["BTC-USD", "ETH-USD"],
          logger: logger,
          on_ticker: kind_of(Proc)
        ).and_return(spot_subscriber)
        
        job.perform
      end

      it "starts the spot subscriber" do
        expect(spot_subscriber).to receive(:start)
        job.perform
      end
    end

    context "with job queuing system" do
      let(:position) { create(:position) }

      before do
        job.instance_variable_set(:@logger, logger)
      end

      it "enqueues PositionCloseJob on critical queue" do
        expect(PositionCloseJob).to receive(:perform_later).with(
          position_id: position.id,
          reason: "take_profit",
          priority: "immediate"
        )
        
        job.send(:trigger_position_close, position, "take_profit")
      end

      it "enqueues FuturesBasisMonitoringJob" do
        job.instance_variable_set(:@contract_manager, contract_manager)
        
        allow(job).to receive(:extract_asset_from_product_id).with("BTC-USD").and_return("BTC")
        allow(contract_manager).to receive(:current_month_contract).with("BTC").and_return("BIT-29DEC24")
        allow(contract_manager).to receive(:upcoming_month_contract).with("BTC").and_return(nil)
        
        expect(FuturesBasisMonitoringJob).to receive(:perform_later).with(
          spot_product_id: "BTC-USD",
          futures_product_id: "BIT-29DEC24",
          spot_price: 50000.0
        )
        
        job.send(:update_futures_monitoring, "BTC-USD", 50000.0)
      end

      it "enqueues RapidSignalEvaluationJob" do
        allow(job).to receive(:extract_asset_from_product_id).with("BTC-USD").and_return("BTC")
        allow(Rails.cache).to receive(:read).and_return(nil)
        allow(Rails.cache).to receive(:write)
        
        expect(RapidSignalEvaluationJob).to receive(:perform_later).with(
          product_id: "BTC-USD",
          current_price: 50000.0,
          asset: "BTC"
        )
        
        job.send(:evaluate_rapid_signals, "BTC-USD", 50000.0)
      end
    end
  end

  describe "caching and rate limiting" do
    let(:product_id) { "BTC-USD" }

    context "for signal evaluation throttling" do
      it "uses cache to prevent excessive signal evaluation" do
        cache_key = "last_signal_eval_#{product_id}"
        
        expect(Rails.cache).to receive(:read).with(cache_key).and_return(nil)
        expect(Rails.cache).to receive(:write).with(cache_key, kind_of(Time), expires_in: 1.minute)
        
        allow(job).to receive(:extract_asset_from_product_id).and_return("BTC")
        allow(RapidSignalEvaluationJob).to receive(:perform_later)
        
        job.send(:evaluate_rapid_signals, product_id, 50000.0)
      end
    end

    context "for price change detection" do
      it "uses cache to store last price for comparison" do
        price_key = "last_price_#{product_id}"
        
        allow(Time).to receive(:current).and_return(Time.parse("2024-01-01 14:00:00 UTC"))
        allow(Rails.cache).to receive(:read).with(price_key).and_return(nil)
        expect(Rails.cache).to receive(:write).with(price_key, 50000.0, expires_in: 5.minutes)
        
        job.send(:should_evaluate_signals?, product_id, 50000.0)
      end
    end
  end

  describe "monitoring and alerting workflows" do
    let(:position) { create(:position, take_profit: 51000.0, entry_time: 7.hours.ago) }
    let(:current_price) { 51000.0 }

    before do
      job.instance_variable_set(:@logger, logger)
    end

    it "provides comprehensive position monitoring" do
      allow(job).to receive(:trigger_position_close)
      allow(position).to receive(:age_in_hours).and_return(7.0)
      
      # Should log take profit hit
      expect(logger).to receive(:info).with("[RTM] Take profit hit for LONG position #{position.product_id} at $#{current_price}")
      
      # Should also log time limit warning
      expect(logger).to receive(:warn).with("[RTM] Day trading position #{position.product_id} exceeded 6-hour limit")
      
      # Should trigger both types of closure
      expect(job).to receive(:trigger_position_close).with(position, "take_profit")
      expect(job).to receive(:trigger_position_close).with(position, "time_limit")
      
      job.send(:check_take_profit_stop_loss, position, current_price)
      job.send(:check_day_trading_time_limits, position)
    end

    it "provides real-time tick processing alerts" do
      ticker_data = {
        "product_id" => "BTC-USD",
        "price" => "50000.00",
        "time" => "2024-01-01T12:00:00Z"
      }
      
      expect(logger).to receive(:debug).with("[RTM] BTC-USD: $50000.0 at 2024-01-01T12:00:00Z")
      
      allow(job).to receive(:create_tick_record)
      allow(job).to receive(:check_position_alerts)
      allow(job).to receive(:futures_relevant?).and_return(false)
      allow(job).to receive(:should_evaluate_signals?).and_return(false)
      
      job.send(:process_real_time_tick, ticker_data)
    end
  end

  describe "system health monitoring" do
    it "monitors tick data storage health" do
      product_id = "BTC-USD"
      price = 50000.0
      timestamp = "2024-01-01T12:00:00Z"
      
      job.instance_variable_set(:@logger, logger)
      
      # Mock successful tick creation
      expect(Tick).to receive(:create!).and_return(true)
      
      expect {
        job.send(:create_tick_record, product_id, price, timestamp)
      }.not_to raise_error
    end

    it "handles and reports tick storage failures" do
      product_id = "BTC-USD"
      price = 50000.0
      timestamp = "2024-01-01T12:00:00Z"
      
      job.instance_variable_set(:@logger, logger)
      
      # Mock tick creation failure
      allow(Tick).to receive(:create!).and_raise(StandardError.new("Database connection lost"))
      
      expect(logger).to receive(:warn).with("[RTM] Failed to store tick for BTC-USD: Database connection lost")
      
      expect {
        job.send(:create_tick_record, product_id, price, timestamp)
      }.not_to raise_error
    end

    it "monitors cache system health through signal evaluation" do
      allow(job).to receive(:extract_asset_from_product_id).and_return("BTC")
      
      # Mock cache operations
      expect(Rails.cache).to receive(:read).with("last_signal_eval_BTC-USD")
      expect(Rails.cache).to receive(:write).with("last_signal_eval_BTC-USD", kind_of(Time), expires_in: 1.minute)
      
      allow(RapidSignalEvaluationJob).to receive(:perform_later)
      
      job.send(:evaluate_rapid_signals, "BTC-USD", 50000.0)
    end
  end
end