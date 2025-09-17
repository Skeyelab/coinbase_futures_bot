# frozen_string_literal: true

require "rails_helper"

RSpec.describe FuturesBasisMonitoringJob, type: :job do
  let(:job) { described_class.new }
  let(:spot_product_id) { "BTC-USD" }
  let(:futures_product_id) { "BTC-29DEC24" }
  let(:spot_price) { 50_000.0 }
  let(:futures_price) { 50_500.0 }
  let(:logger) { instance_double(Logger) }

  before do
    allow(Rails).to receive(:logger).and_return(logger)
    allow(logger).to receive(:debug)
    allow(logger).to receive(:info)
    allow(logger).to receive(:warn)
    allow(Rails.cache).to receive(:write)
    allow(Rails.cache).to receive(:read)
  end

  describe "job configuration" do
    it "uses the default queue" do
      expect(described_class.queue_name).to eq("default")
    end

    it "inherits from ApplicationJob" do
      expect(described_class.superclass).to eq(ApplicationJob)
    end
  end

  describe "#perform" do
    let(:perform_params) do
      {
        spot_product_id: spot_product_id,
        futures_product_id: futures_product_id,
        spot_price: spot_price
      }
    end

    context "when futures price is available from recent tick" do
      let!(:recent_tick) do
        create(:tick, :recent, product_id: futures_product_id, price: futures_price)
      end

      it "calculates basis correctly" do
        expected_basis = futures_price - spot_price
        expected_basis_bps = (expected_basis / spot_price * 10_000).round(2)

        expect(logger).to receive(:debug).with(
          "[FBM] #{futures_product_id} basis: #{expected_basis_bps} bps (F: $#{futures_price}, S: $#{spot_price})"
        )

        job.perform(**perform_params)
      end

      it "stores basis data in cache" do
        expected_basis = futures_price - spot_price
        expected_basis_bps = (expected_basis / spot_price * 10_000).round(2)

        expected_cache_data = {
          spot_price: spot_price,
          futures_price: futures_price,
          basis: expected_basis,
          basis_bps: expected_basis_bps,
          timestamp: kind_of(Time)
        }

        expect(Rails.cache).to receive(:write).with(
          "basis_#{futures_product_id}_latest",
          expected_cache_data,
          expires_in: 1.hour
        )

        job.perform(**perform_params)
      end

      it "processes all monitoring workflows" do
        # Should call all private methods
        expect(job).to receive(:get_futures_price).and_call_original
        expect(job).to receive(:store_basis_data).and_call_original
        expect(job).to receive(:check_arbitrage_opportunities).and_call_original
        expect(job).to receive(:monitor_basis_extremes).and_call_original

        job.perform(**perform_params)
      end
    end

    context "when no recent tick data is available" do
      before do
        # Create old tick data that should be ignored
        create(:tick, :old, product_id: futures_product_id, price: futures_price)
      end

      it "attempts to fetch current market price" do
        expect(job).to receive(:fetch_current_market_price).with(futures_product_id).and_return(nil)
        job.perform(**perform_params)
      end

      it "returns early when no futures price is available" do
        allow(job).to receive(:fetch_current_market_price).and_return(nil)

        expect(job).not_to receive(:store_basis_data)
        expect(job).not_to receive(:check_arbitrage_opportunities)
        expect(job).not_to receive(:monitor_basis_extremes)

        job.perform(**perform_params)
      end
    end

    context "with string spot_price parameter" do
      it "converts spot_price to float" do
        expect {
          job.perform(
            spot_product_id: spot_product_id,
            futures_product_id: futures_product_id,
            spot_price: "50000.50"
          )
        }.not_to raise_error
      end
    end
  end

  describe "#get_futures_price" do
    context "with recent tick data" do
      let!(:recent_tick) do
        create(:tick, :recent, product_id: futures_product_id, price: futures_price)
      end

      it "returns price from recent tick" do
        result = job.send(:get_futures_price, futures_product_id)
        expect(result).to eq(futures_price)
      end

      it "queries ticks within 5 minutes" do
        expect(Tick).to receive(:where).with(product_id: futures_product_id).and_call_original
        job.send(:get_futures_price, futures_product_id)
      end
    end

    context "without recent tick data" do
      before do
        create(:tick, :old, product_id: futures_product_id, price: futures_price)
      end

      it "falls back to market data API" do
        expect(job).to receive(:fetch_current_market_price).with(futures_product_id)
        job.send(:get_futures_price, futures_product_id)
      end
    end

    context "with multiple recent ticks" do
      let!(:older_tick) do
        create(:tick, product_id: futures_product_id, price: 49_000.0, observed_at: 2.minutes.ago)
      end
      let!(:newer_tick) do
        create(:tick, product_id: futures_product_id, price: futures_price, observed_at: 1.minute.ago)
      end

      it "returns the most recent tick price" do
        result = job.send(:get_futures_price, futures_product_id)
        expect(result).to eq(futures_price)
      end
    end
  end

  describe "#fetch_current_market_price" do
    it "returns nil to avoid API calls during high-frequency monitoring" do
      result = job.send(:fetch_current_market_price, futures_product_id)
      expect(result).to be_nil
    end
  end

  describe "#store_basis_data" do
    let(:basis) { 500.0 }
    let(:basis_bps) { 100.0 }

    before do
      job.instance_variable_set(:@spot_price, spot_price)
      job.instance_variable_set(:@futures_product_id, futures_product_id)
    end

    it "stores basis data with correct structure" do
      expected_data = {
        spot_price: spot_price,
        futures_price: spot_price + basis,
        basis: basis,
        basis_bps: basis_bps,
        timestamp: kind_of(Time)
      }

      expect(Rails.cache).to receive(:write).with(
        "basis_#{futures_product_id}_latest",
        expected_data,
        expires_in: 1.hour
      )

      job.send(:store_basis_data, basis, basis_bps)
    end

    it "calculates futures price correctly from basis" do
      expected_futures_price = spot_price + basis

      expect(Rails.cache).to receive(:write) do |key, data, options|
        expect(data[:futures_price]).to eq(expected_futures_price)
      end

      job.send(:store_basis_data, basis, basis_bps)
    end
  end

  describe "#check_arbitrage_opportunities" do
    before do
      job.instance_variable_set(:@spot_product_id, spot_product_id)
      job.instance_variable_set(:@futures_product_id, futures_product_id)
      job.instance_variable_set(:@logger, logger)
    end

    context "when basis exceeds arbitrage threshold" do
      let(:basis_bps) { 75.0 } # Above default 50 bps threshold

      before do
        allow(ENV).to receive(:fetch).with("BASIS_ARBITRAGE_THRESHOLD_BPS", "50").and_return("50")
      end

      it "logs arbitrage opportunity for positive basis" do
        expect(logger).to receive(:info).with(
          "[FBM] Arbitrage opportunity detected: POSITIVE basis #{basis_bps} bps on #{futures_product_id}"
        )

        job.send(:check_arbitrage_opportunities, basis_bps)
      end

      it "logs arbitrage opportunity for negative basis" do
        negative_basis_bps = -75.0

        expect(logger).to receive(:info).with(
          "[FBM] Arbitrage opportunity detected: NEGATIVE basis #{negative_basis_bps} bps on #{futures_product_id}"
        )

        job.send(:check_arbitrage_opportunities, negative_basis_bps)
      end

      it "enqueues ArbitrageOpportunityJob with correct parameters" do
        expect(ArbitrageOpportunityJob).to receive(:perform_later).with(
          spot_product_id: spot_product_id,
          futures_product_id: futures_product_id,
          basis_bps: basis_bps,
          direction: "POSITIVE"
        )

        job.send(:check_arbitrage_opportunities, basis_bps)
      end
    end

    context "when basis is below arbitrage threshold" do
      let(:basis_bps) { 25.0 } # Below default 50 bps threshold

      it "does not log arbitrage opportunity" do
        expect(logger).not_to receive(:info).with(/Arbitrage opportunity detected/)
        job.send(:check_arbitrage_opportunities, basis_bps)
      end

      it "does not enqueue ArbitrageOpportunityJob" do
        expect(ArbitrageOpportunityJob).not_to receive(:perform_later)
        job.send(:check_arbitrage_opportunities, basis_bps)
      end
    end

    context "with custom arbitrage threshold" do
      let(:custom_threshold) { "100" }
      let(:basis_bps) { 75.0 }

      before do
        allow(ENV).to receive(:fetch).with("BASIS_ARBITRAGE_THRESHOLD_BPS", "50").and_return(custom_threshold)
      end

      it "uses custom threshold for arbitrage detection" do
        expect(logger).not_to receive(:info).with(/Arbitrage opportunity detected/)
        expect(ArbitrageOpportunityJob).not_to receive(:perform_later)

        job.send(:check_arbitrage_opportunities, basis_bps)
      end
    end
  end

  describe "#monitor_basis_extremes" do
    before do
      job.instance_variable_set(:@futures_product_id, futures_product_id)
      job.instance_variable_set(:@logger, logger)
    end

    context "when basis exceeds extreme threshold" do
      let(:basis_bps) { 250.0 } # Above default 200 bps threshold

      before do
        allow(ENV).to receive(:fetch).with("BASIS_EXTREME_THRESHOLD_BPS", "200").and_return("200")
      end

      it "logs extreme basis warning" do
        expect(logger).to receive(:warn).with(
          "[FBM] EXTREME BASIS DETECTED: #{basis_bps} bps on #{futures_product_id}"
        )

        job.send(:monitor_basis_extremes, basis_bps)
      end

      it "sends extreme basis alert" do
        expect(job).to receive(:send_extreme_basis_alert).with(basis_bps)
        job.send(:monitor_basis_extremes, basis_bps)
      end

      it "handles negative extreme basis" do
        negative_basis_bps = -250.0

        expect(logger).to receive(:warn).with(
          "[FBM] EXTREME BASIS DETECTED: #{negative_basis_bps} bps on #{futures_product_id}"
        )
        expect(job).to receive(:send_extreme_basis_alert).with(negative_basis_bps)

        job.send(:monitor_basis_extremes, negative_basis_bps)
      end
    end

    context "when basis is below extreme threshold" do
      let(:basis_bps) { 150.0 } # Below default 200 bps threshold

      it "does not log extreme basis warning" do
        expect(logger).not_to receive(:warn).with(/EXTREME BASIS DETECTED/)
        job.send(:monitor_basis_extremes, basis_bps)
      end

      it "does not send extreme basis alert" do
        expect(job).not_to receive(:send_extreme_basis_alert)
        job.send(:monitor_basis_extremes, basis_bps)
      end
    end

    context "with custom extreme threshold" do
      let(:custom_threshold) { "300" }
      let(:basis_bps) { 250.0 }

      before do
        allow(ENV).to receive(:fetch).with("BASIS_EXTREME_THRESHOLD_BPS", "200").and_return(custom_threshold)
      end

      it "uses custom threshold for extreme detection" do
        expect(logger).not_to receive(:warn).with(/EXTREME BASIS DETECTED/)
        expect(job).not_to receive(:send_extreme_basis_alert)

        job.send(:monitor_basis_extremes, basis_bps)
      end
    end
  end

  describe "#send_extreme_basis_alert" do
    let(:basis_bps) { 250.0 }

    before do
      job.instance_variable_set(:@futures_product_id, futures_product_id)
      job.instance_variable_set(:@logger, logger)
    end

    it "logs extreme basis alert" do
      expected_message = "[ALERT] EXTREME BASIS: #{futures_product_id} at #{basis_bps} bps - potential market stress"

      expect(logger).to receive(:warn).with(expected_message)
      job.send(:send_extreme_basis_alert, basis_bps)
    end
  end

  describe "basis calculation accuracy" do
    let!(:recent_tick) do
      create(:tick, :recent, product_id: futures_product_id, price: futures_price)
    end

    context "with different price scenarios" do
      [
        {spot: 50_000.0, futures: 50_500.0, expected_bps: 100.0},
        {spot: 50_000.0, futures: 49_500.0, expected_bps: -100.0},
        {spot: 100_000.0, futures: 100_050.0, expected_bps: 5.0},
        {spot: 25_000.0, futures: 25_012.5, expected_bps: 5.0}
      ].each do |scenario|
        it "calculates #{scenario[:expected_bps]} bps correctly for spot=#{scenario[:spot]} futures=#{scenario[:futures]}" do
          recent_tick.update!(price: scenario[:futures])

          expected_basis = scenario[:futures] - scenario[:spot]
          expected_basis_bps = (expected_basis / scenario[:spot] * 10_000).round(2)

          expect(expected_basis_bps).to eq(scenario[:expected_bps])

          expect(logger).to receive(:debug).with(
            "[FBM] #{futures_product_id} basis: #{expected_basis_bps} bps (F: $#{scenario[:futures]}, S: $#{scenario[:spot]})"
          )

          job.perform(
            spot_product_id: spot_product_id,
            futures_product_id: futures_product_id,
            spot_price: scenario[:spot]
          )
        end
      end
    end

    context "with edge case prices" do
      it "handles very small spot prices" do
        small_spot_price = 0.01
        small_futures_price = 0.0101
        recent_tick.update!(price: small_futures_price)

        expected_basis_bps = ((small_futures_price - small_spot_price) / small_spot_price * 10_000).round(2)

        expect(logger).to receive(:debug).with(
          "[FBM] #{futures_product_id} basis: #{expected_basis_bps} bps (F: $#{small_futures_price}, S: $#{small_spot_price})"
        )

        job.perform(
          spot_product_id: spot_product_id,
          futures_product_id: futures_product_id,
          spot_price: small_spot_price
        )
      end

      it "handles very large prices" do
        large_spot_price = 1_000_000.0
        large_futures_price = 1_001_000.0
        recent_tick.update!(price: large_futures_price)

        expected_basis_bps = ((large_futures_price - large_spot_price) / large_spot_price * 10_000).round(2)

        expect(logger).to receive(:debug).with(
          "[FBM] #{futures_product_id} basis: #{expected_basis_bps} bps (F: $#{large_futures_price}, S: $#{large_spot_price})"
        )

        job.perform(
          spot_product_id: spot_product_id,
          futures_product_id: futures_product_id,
          spot_price: large_spot_price
        )
      end
    end
  end

  describe "error handling and data validation" do
    context "when Tick model raises an error" do
      before do
        allow(Tick).to receive(:where).and_raise(StandardError.new("Database error"))
      end

      it "propagates the error" do
        expect {
          job.perform(
            spot_product_id: spot_product_id,
            futures_product_id: futures_product_id,
            spot_price: spot_price
          )
        }.to raise_error(StandardError, "Database error")
      end
    end

    context "when cache operations fail" do
      before do
        create(:tick, :recent, product_id: futures_product_id, price: futures_price)
        allow(Rails.cache).to receive(:write).and_raise(StandardError.new("Cache error"))
      end

      it "propagates cache write errors" do
        expect {
          job.perform(
            spot_product_id: spot_product_id,
            futures_product_id: futures_product_id,
            spot_price: spot_price
          )
        }.to raise_error(StandardError, "Cache error")
      end
    end

    context "when ArbitrageOpportunityJob fails to enqueue" do
      let!(:recent_tick) do
        create(:tick, :recent, product_id: futures_product_id, price: 52_500.0) # 500 bps basis
      end

      before do
        allow(ENV).to receive(:fetch).with("BASIS_ARBITRAGE_THRESHOLD_BPS", "50").and_return("50")
        allow(ArbitrageOpportunityJob).to receive(:perform_later).and_raise(StandardError.new("Job queue error"))
      end

      it "propagates job enqueue errors" do
        expect {
          job.perform(
            spot_product_id: spot_product_id,
            futures_product_id: futures_product_id,
            spot_price: spot_price
          )
        }.to raise_error(StandardError, "Job queue error")
      end
    end

    context "with invalid spot_price" do
      it "handles zero spot price by producing Infinity basis points" do
        create(:tick, :recent, product_id: futures_product_id, price: futures_price)

        expect(Rails.cache).to receive(:write) do |key, data, options|
          expect(data[:basis_bps]).to eq(Float::INFINITY)
        end

        job.perform(
          spot_product_id: spot_product_id,
          futures_product_id: futures_product_id,
          spot_price: 0
        )
      end

      it "handles negative spot price" do
        create(:tick, :recent, product_id: futures_product_id, price: futures_price)

        # Should still work mathematically, but produces unusual results
        expect {
          job.perform(
            spot_product_id: spot_product_id,
            futures_product_id: futures_product_id,
            spot_price: -1000.0
          )
        }.not_to raise_error
      end
    end
  end

  describe "performance under high-frequency updates" do
    let!(:recent_tick) do
      create(:tick, :recent, product_id: futures_product_id, price: futures_price)
    end

    it "handles multiple rapid calls efficiently" do
      perform_params = {
        spot_product_id: spot_product_id,
        futures_product_id: futures_product_id,
        spot_price: spot_price
      }

      # Simulate high-frequency calls
      expect {
        10.times { job.perform(**perform_params) }
      }.not_to raise_error
    end

    it "maintains data consistency across rapid updates" do
      prices = [50_000.0, 50_100.0, 50_200.0, 50_050.0, 49_900.0]

      prices.each_with_index do |price, index|
        # Clear existing ticks and create a new one for each iteration
        Tick.where(product_id: futures_product_id).delete_all
        create(:tick, :recent, product_id: futures_product_id, price: price, observed_at: Time.current)

        # Each call should use the current tick price
        expect(Rails.cache).to receive(:write) do |key, data, options|
          expect(data[:futures_price]).to eq(price)
        end

        job.perform(
          spot_product_id: spot_product_id,
          futures_product_id: futures_product_id,
          spot_price: spot_price
        )
      end
    end
  end

  describe "historical basis analysis" do
    let!(:recent_tick) do
      create(:tick, :recent, product_id: futures_product_id, price: futures_price)
    end

    it "stores data with timestamp for historical analysis" do
      expect(Rails.cache).to receive(:write) do |key, data, options|
        expect(data[:timestamp]).to be_a(Time)
        expect(data[:timestamp]).to be_within(1.second).of(Time.current)
      end

      job.perform(
        spot_product_id: spot_product_id,
        futures_product_id: futures_product_id,
        spot_price: spot_price
      )
    end

    it "uses appropriate cache expiration for historical data" do
      expect(Rails.cache).to receive(:write).with(
        anything,
        anything,
        expires_in: 1.hour
      )

      job.perform(
        spot_product_id: spot_product_id,
        futures_product_id: futures_product_id,
        spot_price: spot_price
      )
    end

    it "stores complete basis analysis data" do
      expected_basis = futures_price - spot_price
      expected_basis_bps = (expected_basis / spot_price * 10_000).round(2)

      expect(Rails.cache).to receive(:write) do |key, data, options|
        expect(data).to include(
          spot_price: spot_price,
          futures_price: futures_price,
          basis: expected_basis,
          basis_bps: expected_basis_bps,
          timestamp: kind_of(Time)
        )
      end

      job.perform(
        spot_product_id: spot_product_id,
        futures_product_id: futures_product_id,
        spot_price: spot_price
      )
    end
  end

  describe "integration with ActiveJob" do
    it "can be enqueued with required parameters" do
      expect {
        described_class.perform_later(
          spot_product_id: spot_product_id,
          futures_product_id: futures_product_id,
          spot_price: spot_price
        )
      }.not_to raise_error
    end

    it "allows enqueuing with missing parameters (validation happens at perform time)" do
      expect {
        described_class.perform_later(spot_product_id: spot_product_id)
      }.not_to raise_error
    end
  end

  describe "environment variable configuration" do
    context "BASIS_ARBITRAGE_THRESHOLD_BPS" do
      it "uses default value when not set" do
        allow(ENV).to receive(:fetch).with("BASIS_ARBITRAGE_THRESHOLD_BPS", "50").and_return("50")

        job.instance_variable_set(:@spot_product_id, spot_product_id)
        job.instance_variable_set(:@futures_product_id, futures_product_id)
        job.instance_variable_set(:@logger, logger)

        # 60 bps should trigger with default 50 bps threshold
        expect(logger).to receive(:info).with(/Arbitrage opportunity detected/)
        expect(ArbitrageOpportunityJob).to receive(:perform_later)
        job.send(:check_arbitrage_opportunities, 60.0)
      end

      it "respects custom environment value" do
        allow(ENV).to receive(:fetch).with("BASIS_ARBITRAGE_THRESHOLD_BPS", "50").and_return("100")

        job.instance_variable_set(:@spot_product_id, spot_product_id)
        job.instance_variable_set(:@futures_product_id, futures_product_id)
        job.instance_variable_set(:@logger, logger)

        # 60 bps should NOT trigger with 100 bps threshold
        expect(logger).not_to receive(:info)
        expect(ArbitrageOpportunityJob).not_to receive(:perform_later)
        job.send(:check_arbitrage_opportunities, 60.0)
      end
    end

    context "BASIS_EXTREME_THRESHOLD_BPS" do
      it "uses default value when not set" do
        allow(ENV).to receive(:fetch).with("BASIS_EXTREME_THRESHOLD_BPS", "200").and_return("200")

        job.instance_variable_set(:@futures_product_id, futures_product_id)
        job.instance_variable_set(:@logger, logger)

        # 250 bps should trigger with default 200 bps threshold
        expect(logger).to receive(:warn).with(/EXTREME BASIS DETECTED/)
        expect(job).to receive(:send_extreme_basis_alert)
        job.send(:monitor_basis_extremes, 250.0)
      end

      it "respects custom environment value" do
        allow(ENV).to receive(:fetch).with("BASIS_EXTREME_THRESHOLD_BPS", "200").and_return("400")

        job.instance_variable_set(:@futures_product_id, futures_product_id)
        job.instance_variable_set(:@logger, logger)

        # 250 bps should NOT trigger with 400 bps threshold
        expect(logger).not_to receive(:warn)
        expect(job).not_to receive(:send_extreme_basis_alert)
        job.send(:monitor_basis_extremes, 250.0)
      end
    end
  end
end
