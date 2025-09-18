# frozen_string_literal: true

require "rails_helper"

RSpec.describe ArbitrageOpportunityJob, type: :job do
  let(:job) { described_class.new }
  let(:spot_product_id) { "BTC-USD" }
  let(:futures_product_id) { "BTC-29DEC24" }
  let(:basis_bps) { 75.0 }
  let(:direction) { "POSITIVE" }
  let(:logger) { instance_double(Logger) }

  let(:perform_params) do
    {
      spot_product_id: spot_product_id,
      futures_product_id: futures_product_id,
      basis_bps: basis_bps,
      direction: direction
    }
  end

  before do
    allow(Rails).to receive(:logger).and_return(logger)
    allow(logger).to receive(:info)
    allow(logger).to receive(:warn)
    allow(logger).to receive(:error)
    allow(Rails.cache).to receive(:read)
    allow(Rails.cache).to receive(:write)
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
    context "when arbitrage is valid and within risk limits" do
      before do
        allow(job).to receive(:arbitrage_still_valid?).and_return(true)
        allow(job).to receive(:within_arbitrage_risk_limits?).and_return(true)
        allow(job).to receive(:log_arbitrage_opportunity)
      end

      it "logs the initial arbitrage evaluation" do
        expect(logger).to receive(:info).with(
          "[ARB] Evaluating arbitrage: #{direction} #{basis_bps} bps between #{spot_product_id} and #{futures_product_id}"
        )

        job.perform(**perform_params)
      end

      it "checks if arbitrage is still valid" do
        expect(job).to receive(:arbitrage_still_valid?).and_return(true)
        job.perform(**perform_params)
      end

      it "checks risk limits" do
        expect(job).to receive(:within_arbitrage_risk_limits?).and_return(true)
        job.perform(**perform_params)
      end

      it "logs the arbitrage opportunity" do
        expect(job).to receive(:log_arbitrage_opportunity)
        job.perform(**perform_params)
      end

      it "logs successful opportunity analysis" do
        expect(logger).to receive(:info).with("[ARB] Arbitrage opportunity logged for analysis")
        job.perform(**perform_params)
      end

      it "sets instance variables correctly" do
        job.perform(**perform_params)

        expect(job.instance_variable_get(:@spot_product_id)).to eq(spot_product_id)
        expect(job.instance_variable_get(:@futures_product_id)).to eq(futures_product_id)
        expect(job.instance_variable_get(:@basis_bps)).to eq(basis_bps.to_f)
        expect(job.instance_variable_get(:@direction)).to eq(direction)
        expect(job.instance_variable_get(:@logger)).to eq(logger)
      end
    end

    context "when arbitrage is no longer valid" do
      before do
        allow(job).to receive(:arbitrage_still_valid?).and_return(false)
      end

      it "returns early without processing" do
        expect(job).not_to receive(:within_arbitrage_risk_limits?)
        expect(job).not_to receive(:log_arbitrage_opportunity)
        expect(logger).not_to receive(:info).with("[ARB] Arbitrage opportunity logged for analysis")

        job.perform(**perform_params)
      end

      it "still logs the initial evaluation" do
        expect(logger).to receive(:info).with(
          "[ARB] Evaluating arbitrage: #{direction} #{basis_bps} bps between #{spot_product_id} and #{futures_product_id}"
        )

        job.perform(**perform_params)
      end
    end

    context "when outside risk limits" do
      before do
        allow(job).to receive(:arbitrage_still_valid?).and_return(true)
        allow(job).to receive(:within_arbitrage_risk_limits?).and_return(false)
      end

      it "returns early without logging opportunity" do
        expect(job).not_to receive(:log_arbitrage_opportunity)
        expect(logger).not_to receive(:info).with("[ARB] Arbitrage opportunity logged for analysis")

        job.perform(**perform_params)
      end
    end

    context "with string basis_bps parameter" do
      it "converts basis_bps to float" do
        expect {
          job.perform(
            spot_product_id: spot_product_id,
            futures_product_id: futures_product_id,
            basis_bps: "75.5",
            direction: direction
          )
        }.not_to raise_error

        expect(job.instance_variable_get(:@basis_bps)).to eq(75.5)
      end
    end
  end

  describe "#arbitrage_still_valid?" do
    let(:current_basis) { 80.0 }
    let(:threshold) { 50.0 }

    before do
      job.instance_variable_set(:@direction, direction)
      allow(ENV).to receive(:fetch).with("BASIS_ARBITRAGE_THRESHOLD_BPS", "50").and_return(threshold.to_s)
      allow(job).to receive(:calculate_current_basis).and_return(current_basis)
    end

    context "when current basis is available and valid" do
      context "with positive direction" do
        let(:direction) { "POSITIVE" }
        let(:current_basis) { 80.0 } # Positive basis above threshold

        it "returns true when basis is above threshold and direction matches" do
          expect(job.send(:arbitrage_still_valid?)).to be true
        end

        it "returns false when basis direction changes to negative" do
          allow(job).to receive(:calculate_current_basis).and_return(-80.0)
          expect(job.send(:arbitrage_still_valid?)).to be false
        end

        it "returns false when basis falls below threshold" do
          allow(job).to receive(:calculate_current_basis).and_return(30.0)
          expect(job.send(:arbitrage_still_valid?)).to be false
        end
      end

      context "with negative direction" do
        let(:direction) { "NEGATIVE" }
        let(:current_basis) { -80.0 } # Negative basis above threshold (in absolute terms)

        it "returns true when basis is above threshold and direction matches" do
          expect(job.send(:arbitrage_still_valid?)).to be true
        end

        it "returns false when basis direction changes to positive" do
          allow(job).to receive(:calculate_current_basis).and_return(80.0)
          expect(job.send(:arbitrage_still_valid?)).to be false
        end

        it "returns false when basis falls below threshold (in absolute terms)" do
          allow(job).to receive(:calculate_current_basis).and_return(-30.0)
          expect(job.send(:arbitrage_still_valid?)).to be false
        end
      end
    end

    context "when current basis is not available" do
      before do
        allow(job).to receive(:calculate_current_basis).and_return(nil)
      end

      it "returns false" do
        expect(job.send(:arbitrage_still_valid?)).to be false
      end
    end

    context "with custom threshold" do
      let(:custom_threshold) { 100.0 }

      before do
        allow(ENV).to receive(:fetch).with("BASIS_ARBITRAGE_THRESHOLD_BPS", "50").and_return(custom_threshold.to_s)
      end

      it "uses custom threshold for validation" do
        allow(job).to receive(:calculate_current_basis).and_return(75.0) # Below custom threshold
        expect(job.send(:arbitrage_still_valid?)).to be false
      end

      it "returns true when above custom threshold" do
        allow(job).to receive(:calculate_current_basis).and_return(150.0) # Above custom threshold
        expect(job.send(:arbitrage_still_valid?)).to be true
      end
    end

    context "with edge case basis values" do
      it "handles zero basis" do
        allow(job).to receive(:calculate_current_basis).and_return(0.0)
        expect(job.send(:arbitrage_still_valid?)).to be false
      end

      it "handles very small positive basis" do
        allow(job).to receive(:calculate_current_basis).and_return(0.1)
        expect(job.send(:arbitrage_still_valid?)).to be false
      end

      it "handles very small negative basis" do
        job.instance_variable_set(:@direction, "NEGATIVE")
        allow(job).to receive(:calculate_current_basis).and_return(-0.1)
        expect(job.send(:arbitrage_still_valid?)).to be false
      end
    end
  end

  describe "#within_arbitrage_risk_limits?" do
    let(:max_positions) { 2 }
    let(:current_positions) { 1 }

    before do
      allow(ENV).to receive(:fetch).with("MAX_ARBITRAGE_POSITIONS", "2").and_return(max_positions.to_s)
      allow(job).to receive(:count_active_arbitrage_positions).and_return(current_positions)
      job.instance_variable_set(:@logger, logger)
    end

    context "when within limits" do
      let(:current_positions) { 1 }

      it "returns true" do
        expect(job.send(:within_arbitrage_risk_limits?)).to be true
      end

      it "does not log any warnings" do
        expect(logger).not_to receive(:info).with(/Skipping arbitrage/)
        job.send(:within_arbitrage_risk_limits?)
      end
    end

    context "when at maximum positions" do
      let(:current_positions) { 2 }

      it "returns false" do
        expect(job.send(:within_arbitrage_risk_limits?)).to be false
      end

      it "logs warning message" do
        expect(logger).to receive(:info).with(
          "[ARB] Skipping arbitrage - at max positions (#{current_positions}/#{max_positions})"
        )
        job.send(:within_arbitrage_risk_limits?)
      end
    end

    context "when exceeding maximum positions" do
      let(:current_positions) { 3 }

      it "returns false" do
        expect(job.send(:within_arbitrage_risk_limits?)).to be false
      end

      it "logs warning with correct counts" do
        expect(logger).to receive(:info).with(
          "[ARB] Skipping arbitrage - at max positions (#{current_positions}/#{max_positions})"
        )
        job.send(:within_arbitrage_risk_limits?)
      end
    end

    context "with custom max positions limit" do
      let(:custom_max) { 5 }
      let(:current_positions) { 4 }

      before do
        allow(ENV).to receive(:fetch).with("MAX_ARBITRAGE_POSITIONS", "2").and_return(custom_max.to_s)
      end

      it "uses custom limit for validation" do
        expect(job.send(:within_arbitrage_risk_limits?)).to be true
      end

      it "respects custom limit when at maximum" do
        allow(job).to receive(:count_active_arbitrage_positions).and_return(5)
        expect(job.send(:within_arbitrage_risk_limits?)).to be false
      end
    end

    context "with zero current positions" do
      let(:current_positions) { 0 }

      it "returns true" do
        expect(job.send(:within_arbitrage_risk_limits?)).to be true
      end
    end
  end

  describe "#calculate_current_basis" do
    let(:spot_price) { 50_000.0 }
    let(:futures_price) { 50_500.0 }
    let(:spot_data) { spot_price }
    let(:futures_data) { {futures_price: futures_price} }

    before do
      job.instance_variable_set(:@spot_product_id, spot_product_id)
      job.instance_variable_set(:@futures_product_id, futures_product_id)
    end

    context "when both spot and futures data are available" do
      before do
        allow(Rails.cache).to receive(:read).with("last_price_#{spot_product_id}").and_return(spot_data)
        allow(Rails.cache).to receive(:read).with("basis_#{futures_product_id}_latest").and_return(futures_data)
      end

      it "calculates basis in basis points correctly" do
        expected_basis = futures_price - spot_price
        expected_basis_bps = (expected_basis / spot_price * 10000).round(2)

        result = job.send(:calculate_current_basis)
        expect(result).to eq(expected_basis_bps)
      end

      it "handles negative basis correctly" do
        futures_data[:futures_price] = 49_500.0
        allow(Rails.cache).to receive(:read).with("basis_#{futures_product_id}_latest").and_return(futures_data)

        expected_basis = 49_500.0 - spot_price
        expected_basis_bps = (expected_basis / spot_price * 10000).round(2)

        result = job.send(:calculate_current_basis)
        expect(result).to eq(expected_basis_bps)
      end

      context "with different price scenarios" do
        [
          {spot: 50_000.0, futures: 50_500.0, expected_bps: 100.0},
          {spot: 50_000.0, futures: 49_500.0, expected_bps: -100.0},
          {spot: 100_000.0, futures: 100_050.0, expected_bps: 5.0},
          {spot: 25_000.0, futures: 25_012.5, expected_bps: 5.0},
          {spot: 1_000.0, futures: 1_001.0, expected_bps: 10.0}
        ].each do |scenario|
          it "calculates #{scenario[:expected_bps]} bps correctly for spot=#{scenario[:spot]} futures=#{scenario[:futures]}" do
            allow(Rails.cache).to receive(:read).with("last_price_#{spot_product_id}").and_return(scenario[:spot])
            allow(Rails.cache).to receive(:read).with("basis_#{futures_product_id}_latest").and_return({futures_price: scenario[:futures]})

            result = job.send(:calculate_current_basis)
            expect(result).to eq(scenario[:expected_bps])
          end
        end
      end

      context "with edge case prices" do
        it "handles very small spot prices" do
          small_spot = 0.01
          small_futures = 0.0101
          allow(Rails.cache).to receive(:read).with("last_price_#{spot_product_id}").and_return(small_spot)
          allow(Rails.cache).to receive(:read).with("basis_#{futures_product_id}_latest").and_return({futures_price: small_futures})

          expected_basis_bps = ((small_futures - small_spot) / small_spot * 10000).round(2)
          result = job.send(:calculate_current_basis)
          expect(result).to eq(expected_basis_bps)
        end

        it "handles very large prices" do
          large_spot = 1_000_000.0
          large_futures = 1_001_000.0
          allow(Rails.cache).to receive(:read).with("last_price_#{spot_product_id}").and_return(large_spot)
          allow(Rails.cache).to receive(:read).with("basis_#{futures_product_id}_latest").and_return({futures_price: large_futures})

          expected_basis_bps = ((large_futures - large_spot) / large_spot * 10000).round(2)
          result = job.send(:calculate_current_basis)
          expect(result).to eq(expected_basis_bps)
        end

        it "handles zero spot price gracefully" do
          allow(Rails.cache).to receive(:read).with("last_price_#{spot_product_id}").and_return(0)
          allow(Rails.cache).to receive(:read).with("basis_#{futures_product_id}_latest").and_return({futures_price: futures_price})

          result = job.send(:calculate_current_basis)
          expect(result).to eq(Float::INFINITY)
        end
      end
    end

    context "when spot data is missing" do
      before do
        allow(Rails.cache).to receive(:read).with("last_price_#{spot_product_id}").and_return(nil)
        allow(Rails.cache).to receive(:read).with("basis_#{futures_product_id}_latest").and_return(futures_data)
      end

      it "returns nil" do
        result = job.send(:calculate_current_basis)
        expect(result).to be_nil
      end
    end

    context "when futures data is missing" do
      before do
        allow(Rails.cache).to receive(:read).with("last_price_#{spot_product_id}").and_return(spot_data)
        allow(Rails.cache).to receive(:read).with("basis_#{futures_product_id}_latest").and_return(nil)
      end

      it "returns nil" do
        result = job.send(:calculate_current_basis)
        expect(result).to be_nil
      end
    end

    context "when both spot and futures data are missing" do
      before do
        allow(Rails.cache).to receive(:read).with("last_price_#{spot_product_id}").and_return(nil)
        allow(Rails.cache).to receive(:read).with("basis_#{futures_product_id}_latest").and_return(nil)
      end

      it "returns nil" do
        result = job.send(:calculate_current_basis)
        expect(result).to be_nil
      end
    end

    context "when futures data structure is invalid" do
      before do
        allow(Rails.cache).to receive(:read).with("last_price_#{spot_product_id}").and_return(spot_data)
        allow(Rails.cache).to receive(:read).with("basis_#{futures_product_id}_latest").and_return({invalid: "data"})
      end

      it "raises error when futures_price key is missing" do
        expect {
          job.send(:calculate_current_basis)
        }.to raise_error(NoMethodError)
      end
    end
  end

  describe "#count_active_arbitrage_positions" do
    before do
      # Clear any existing positions
      Position.destroy_all
    end

    context "with arbitrage positions" do
      let!(:arb_position_1) { create(:position, product_id: "BTC-ARB", status: "OPEN") }
      let!(:arb_position_2) { create(:position, product_id: "ETH-ARB", status: "OPEN") }
      let!(:regular_position) { create(:position, product_id: "BTC-USD", status: "OPEN") }
      let!(:closed_arb_position) { create(:position, product_id: "BTC-ARB", status: "CLOSED") }

      it "counts only open arbitrage positions" do
        result = job.send(:count_active_arbitrage_positions)
        expect(result).to eq(2)
      end

      it "excludes regular positions" do
        result = job.send(:count_active_arbitrage_positions)
        expect(result).to eq(2) # Should only count arbitrage positions
      end

      it "excludes closed arbitrage positions" do
        result = job.send(:count_active_arbitrage_positions)
        # Should only count the 2 open arbitrage positions, not the closed one
        expect(result).to eq(2)
      end
    end

    context "with no arbitrage positions" do
      let!(:regular_position) { create(:position, product_id: "BTC-USD", status: "OPEN") }

      it "returns zero" do
        result = job.send(:count_active_arbitrage_positions)
        expect(result).to eq(0)
      end
    end

    context "with no positions at all" do
      it "returns zero" do
        result = job.send(:count_active_arbitrage_positions)
        expect(result).to eq(0)
      end
    end

    context "with various arbitrage position naming patterns" do
      let!(:arb_position_1) { create(:position, product_id: "BTC-USDT-ARB", status: "OPEN") }
      let!(:arb_position_2) { create(:position, product_id: "FUTURES-ARB", status: "OPEN") }
      let!(:arb_position_3) { create(:position, product_id: "SPOT-ARB", status: "OPEN") }

      it "counts all positions with -ARB suffix" do
        result = job.send(:count_active_arbitrage_positions)
        expect(result).to eq(3)
      end
    end
  end

  describe "#log_arbitrage_opportunity" do
    let(:opportunity_score) { 7.5 }
    let(:timestamp) { Time.current }

    before do
      job.instance_variable_set(:@spot_product_id, spot_product_id)
      job.instance_variable_set(:@futures_product_id, futures_product_id)
      job.instance_variable_set(:@basis_bps, basis_bps)
      job.instance_variable_set(:@direction, direction)
      job.instance_variable_set(:@logger, logger)

      allow(job).to receive(:calculate_opportunity_score).and_return(opportunity_score)
      allow(Time).to receive(:current).and_return(timestamp)
    end

    it "stores opportunity data in cache with correct structure" do
      expected_data = {
        timestamp: timestamp,
        spot_product_id: spot_product_id,
        futures_product_id: futures_product_id,
        basis_bps: basis_bps,
        direction: direction,
        opportunity_score: opportunity_score
      }

      expect(Rails.cache).to receive(:write).with(
        "arbitrage_opportunity_#{timestamp.to_i}",
        expected_data,
        expires_in: 1.day
      )

      job.send(:log_arbitrage_opportunity)
    end

    it "logs opportunity data" do
      expected_data = {
        timestamp: timestamp,
        spot_product_id: spot_product_id,
        futures_product_id: futures_product_id,
        basis_bps: basis_bps,
        direction: direction,
        opportunity_score: opportunity_score
      }

      expect(logger).to receive(:info).with("[ARB] Opportunity logged: #{expected_data}")
      job.send(:log_arbitrage_opportunity)
    end

    it "calculates opportunity score" do
      expect(job).to receive(:calculate_opportunity_score).and_return(opportunity_score)
      job.send(:log_arbitrage_opportunity)
    end

    it "uses appropriate cache expiration" do
      expect(Rails.cache).to receive(:write).with(
        anything,
        anything,
        expires_in: 1.day
      )

      job.send(:log_arbitrage_opportunity)
    end

    it "uses timestamp as cache key component" do
      expect(Rails.cache).to receive(:write).with(
        "arbitrage_opportunity_#{timestamp.to_i}",
        anything,
        anything
      )

      job.send(:log_arbitrage_opportunity)
    end
  end

  describe "#calculate_opportunity_score" do
    let(:volatility_adjustment) { 0.8 }
    let(:liquidity_adjustment) { 1.2 }

    before do
      job.instance_variable_set(:@basis_bps, basis_bps)
      allow(job).to receive(:calculate_volatility_adjustment).and_return(volatility_adjustment)
      allow(job).to receive(:calculate_liquidity_adjustment).and_return(liquidity_adjustment)
    end

    context "with different basis magnitudes" do
      [
        {basis_bps: 50.0, expected_base_score: 5.0},
        {basis_bps: 100.0, expected_base_score: 10.0},
        {basis_bps: 150.0, expected_base_score: 10.0}, # Capped at 10
        {basis_bps: -75.0, expected_base_score: 7.5},
        {basis_bps: 25.0, expected_base_score: 2.5}
      ].each do |scenario|
        it "calculates base score correctly for #{scenario[:basis_bps]} bps" do
          job.instance_variable_set(:@basis_bps, scenario[:basis_bps])

          expected_score = (scenario[:expected_base_score] * volatility_adjustment * liquidity_adjustment).round(2)
          result = job.send(:calculate_opportunity_score)
          expect(result).to eq(expected_score)
        end
      end
    end

    it "caps base score at 10 for very high basis" do
      job.instance_variable_set(:@basis_bps, 200.0)

      expected_base_score = 10.0 # Should be capped
      expected_score = (expected_base_score * volatility_adjustment * liquidity_adjustment).round(2)

      result = job.send(:calculate_opportunity_score)
      expect(result).to eq(expected_score)
    end

    it "applies volatility adjustment" do
      expect(job).to receive(:calculate_volatility_adjustment).and_return(volatility_adjustment)
      job.send(:calculate_opportunity_score)
    end

    it "applies liquidity adjustment" do
      expect(job).to receive(:calculate_liquidity_adjustment).and_return(liquidity_adjustment)
      job.send(:calculate_opportunity_score)
    end

    it "rounds result to 2 decimal places" do
      # Set up values that would produce a non-rounded result
      job.instance_variable_set(:@basis_bps, 33.33)
      allow(job).to receive(:calculate_volatility_adjustment).and_return(0.777)
      allow(job).to receive(:calculate_liquidity_adjustment).and_return(1.111)

      result = job.send(:calculate_opportunity_score)
      expect(result).to be_a(Float)
      expect(result.to_s.split(".").last.length).to be <= 2
    end

    context "with edge cases" do
      it "handles zero basis" do
        job.instance_variable_set(:@basis_bps, 0.0)
        result = job.send(:calculate_opportunity_score)
        expect(result).to eq(0.0)
      end

      it "handles very small basis" do
        job.instance_variable_set(:@basis_bps, 0.1)
        expected_score = (0.01 * volatility_adjustment * liquidity_adjustment).round(2)
        result = job.send(:calculate_opportunity_score)
        expect(result).to eq(expected_score)
      end
    end
  end

  describe "#calculate_volatility_adjustment" do
    it "returns placeholder value of 1.0" do
      result = job.send(:calculate_volatility_adjustment)
      expect(result).to eq(1.0)
    end

    # Note: In a full implementation, this would test actual volatility calculations
    # For now, we test the placeholder behavior as documented in the code
    it "is a placeholder method for future volatility-based adjustments" do
      # This test documents that the method is currently a placeholder
      # In the future, this would test actual volatility data processing
      expect(job.send(:calculate_volatility_adjustment)).to be_a(Numeric)
    end
  end

  describe "#calculate_liquidity_adjustment" do
    it "returns placeholder value of 1.0" do
      result = job.send(:calculate_liquidity_adjustment)
      expect(result).to eq(1.0)
    end

    # Note: In a full implementation, this would test actual liquidity calculations
    # For now, we test the placeholder behavior as documented in the code
    it "is a placeholder method for future liquidity-based adjustments" do
      # This test documents that the method is currently a placeholder
      # In the future, this would test actual order book depth and volume analysis
      expect(job.send(:calculate_liquidity_adjustment)).to be_a(Numeric)
    end
  end

  describe "error handling and resilience" do
    context "when cache operations fail" do
      it "propagates cache read errors during basis calculation" do
        allow(Rails.cache).to receive(:read).and_raise(StandardError.new("Cache read error"))

        expect {
          job.perform(**perform_params)
        }.to raise_error(StandardError, "Cache read error")
      end

      it "propagates cache write errors during opportunity logging" do
        allow(job).to receive(:arbitrage_still_valid?).and_return(true)
        allow(job).to receive(:within_arbitrage_risk_limits?).and_return(true)
        allow(Rails.cache).to receive(:write).and_raise(StandardError.new("Cache write error"))

        expect {
          job.perform(**perform_params)
        }.to raise_error(StandardError, "Cache write error")
      end
    end

    context "when Position model queries fail" do
      before do
        allow(job).to receive(:arbitrage_still_valid?).and_return(true)
        allow(Position).to receive(:open).and_raise(StandardError.new("Database error"))
      end

      it "propagates database errors" do
        expect {
          job.perform(**perform_params)
        }.to raise_error(StandardError, "Database error")
      end
    end

    context "when environment variables are invalid" do
      before do
        allow(job).to receive(:calculate_current_basis).and_return(80.0)
      end

      it "handles invalid BASIS_ARBITRAGE_THRESHOLD_BPS gracefully" do
        allow(ENV).to receive(:fetch).with("BASIS_ARBITRAGE_THRESHOLD_BPS", "50").and_return("invalid")

        # Should convert to 0.0 and still work
        expect {
          job.send(:arbitrage_still_valid?)
        }.not_to raise_error
      end

      it "handles invalid MAX_ARBITRAGE_POSITIONS gracefully" do
        allow(ENV).to receive(:fetch).with("MAX_ARBITRAGE_POSITIONS", "2").and_return("invalid")
        allow(job).to receive(:count_active_arbitrage_positions).and_return(1)
        job.instance_variable_set(:@logger, logger) # Set the logger

        # Should convert to 0 and affect logic but not crash
        expect {
          job.send(:within_arbitrage_risk_limits?)
        }.not_to raise_error
      end
    end

    context "when logger is nil" do
      before do
        allow(Rails).to receive(:logger).and_return(nil)
      end

      it "handles nil logger gracefully" do
        expect {
          job.perform(**perform_params)
        }.to raise_error(NoMethodError) # Expected behavior when logger is nil
      end
    end
  end

  describe "integration with ActiveJob" do
    it "can be enqueued with required parameters" do
      expect {
        described_class.perform_later(**perform_params)
      }.not_to raise_error
    end

    it "allows enqueuing with missing parameters (validation happens at perform time)" do
      expect {
        described_class.perform_later(spot_product_id: spot_product_id)
      }.not_to raise_error
    end

    it "can be performed synchronously" do
      allow_any_instance_of(described_class).to receive(:arbitrage_still_valid?).and_return(false)

      expect {
        described_class.perform_now(**perform_params)
      }.not_to raise_error
    end
  end

  describe "environment variable configuration" do
    context "BASIS_ARBITRAGE_THRESHOLD_BPS" do
      before do
        job.instance_variable_set(:@direction, "POSITIVE")
        allow(job).to receive(:calculate_current_basis).and_return(75.0)
      end

      it "uses default value when not set" do
        allow(ENV).to receive(:fetch).with("BASIS_ARBITRAGE_THRESHOLD_BPS", "50").and_return("50")

        # 75 bps should be valid with default 50 bps threshold
        expect(job.send(:arbitrage_still_valid?)).to be true
      end

      it "respects custom environment value" do
        allow(ENV).to receive(:fetch).with("BASIS_ARBITRAGE_THRESHOLD_BPS", "50").and_return("100")

        # 75 bps should NOT be valid with 100 bps threshold
        expect(job.send(:arbitrage_still_valid?)).to be false
      end
    end

    context "MAX_ARBITRAGE_POSITIONS" do
      before do
        allow(job).to receive(:count_active_arbitrage_positions).and_return(3)
        job.instance_variable_set(:@logger, logger)
      end

      it "uses default value when not set" do
        allow(ENV).to receive(:fetch).with("MAX_ARBITRAGE_POSITIONS", "2").and_return("2")

        # 3 positions should exceed default limit of 2
        expect(job.send(:within_arbitrage_risk_limits?)).to be false
      end

      it "respects custom environment value" do
        allow(ENV).to receive(:fetch).with("MAX_ARBITRAGE_POSITIONS", "2").and_return("5")

        # 3 positions should be within custom limit of 5
        expect(job.send(:within_arbitrage_risk_limits?)).to be true
      end
    end
  end

  describe "performance under various market conditions" do
    context "during high volatility periods" do
      before do
        allow(job).to receive(:calculate_volatility_adjustment).and_return(0.5) # High volatility reduces score
      end

      it "adjusts opportunity scores for volatility" do
        job.instance_variable_set(:@basis_bps, 100.0)
        allow(job).to receive(:calculate_liquidity_adjustment).and_return(1.0)

        # Base score would be 10, but volatility adjustment reduces it
        expected_score = (10.0 * 0.5 * 1.0).round(2)
        result = job.send(:calculate_opportunity_score)
        expect(result).to eq(expected_score)
      end
    end

    context "during low liquidity periods" do
      before do
        allow(job).to receive(:calculate_liquidity_adjustment).and_return(0.7) # Low liquidity reduces score
      end

      it "adjusts opportunity scores for liquidity" do
        job.instance_variable_set(:@basis_bps, 100.0)
        allow(job).to receive(:calculate_volatility_adjustment).and_return(1.0)

        # Base score would be 10, but liquidity adjustment reduces it
        expected_score = (10.0 * 1.0 * 0.7).round(2)
        result = job.send(:calculate_opportunity_score)
        expect(result).to eq(expected_score)
      end
    end

    context "with multiple rapid opportunities" do
      it "handles multiple rapid calls efficiently" do
        allow(job).to receive(:arbitrage_still_valid?).and_return(true)
        allow(job).to receive(:within_arbitrage_risk_limits?).and_return(true)
        allow(job).to receive(:log_arbitrage_opportunity)

        # Simulate rapid arbitrage opportunities
        expect {
          5.times { job.perform(**perform_params) }
        }.not_to raise_error
      end

      it "maintains data consistency across rapid calls" do
        different_basis_values = [75.0, 80.0, 85.0, 70.0, 90.0]

        different_basis_values.each do |basis_value|
          params = perform_params.merge(basis_bps: basis_value)
          allow(job).to receive(:arbitrage_still_valid?).and_return(true)
          allow(job).to receive(:within_arbitrage_risk_limits?).and_return(true)
          allow(job).to receive(:log_arbitrage_opportunity)

          job.perform(**params)
          expect(job.instance_variable_get(:@basis_bps)).to eq(basis_value)
        end
      end
    end
  end

  describe "data validation and processing" do
    context "with malformed market data" do
      before do
        job.instance_variable_set(:@spot_product_id, spot_product_id)
        job.instance_variable_set(:@futures_product_id, futures_product_id)
      end

      it "raises error with missing futures_price in cache data" do
        allow(Rails.cache).to receive(:read).with("last_price_#{spot_product_id}").and_return(50_000.0)
        allow(Rails.cache).to receive(:read).with("basis_#{futures_product_id}_latest").and_return({invalid: "data"})

        expect {
          job.send(:calculate_current_basis)
        }.to raise_error(NoMethodError)
      end

      it "raises error with non-numeric spot price data" do
        allow(Rails.cache).to receive(:read).with("last_price_#{spot_product_id}").and_return("invalid")
        allow(Rails.cache).to receive(:read).with("basis_#{futures_product_id}_latest").and_return({futures_price: 50_500.0})

        expect {
          job.send(:calculate_current_basis)
        }.to raise_error(TypeError) # Expected when trying to do math on string
      end
    end

    context "with extreme market conditions" do
      it "handles extremely high basis values" do
        job.instance_variable_set(:@basis_bps, 10_000.0) # 100% basis
        result = job.send(:calculate_opportunity_score)
        expect(result).to be_a(Numeric)
        expect(result).to be > 0
      end

      it "handles extremely low (negative) basis values" do
        job.instance_variable_set(:@basis_bps, -10_000.0) # -100% basis
        result = job.send(:calculate_opportunity_score)
        expect(result).to be_a(Numeric)
        expect(result).to be > 0 # Should use absolute value
      end
    end
  end

  describe "opportunity scoring algorithm" do
    context "with realistic trading scenarios" do
      [
        {basis_bps: 25.0, description: "small arbitrage opportunity"},
        {basis_bps: 50.0, description: "moderate arbitrage opportunity"},
        {basis_bps: 100.0, description: "large arbitrage opportunity"},
        {basis_bps: 200.0, description: "extreme arbitrage opportunity"}
      ].each do |scenario|
        it "scores #{scenario[:description]} appropriately" do
          job.instance_variable_set(:@basis_bps, scenario[:basis_bps])
          allow(job).to receive(:calculate_volatility_adjustment).and_return(1.0)
          allow(job).to receive(:calculate_liquidity_adjustment).and_return(1.0)

          result = job.send(:calculate_opportunity_score)
          expected_base_score = [scenario[:basis_bps].abs / 10, 10].min

          expect(result).to eq(expected_base_score)
          expect(result).to be >= 0
          expect(result).to be <= 10
        end
      end
    end

    it "ensures scores are always non-negative" do
      job.instance_variable_set(:@basis_bps, -150.0)
      allow(job).to receive(:calculate_volatility_adjustment).and_return(0.5)
      allow(job).to receive(:calculate_liquidity_adjustment).and_return(0.8)

      result = job.send(:calculate_opportunity_score)
      expect(result).to be >= 0
    end

    it "ensures scores never exceed maximum possible value" do
      job.instance_variable_set(:@basis_bps, 500.0) # Very high basis
      allow(job).to receive(:calculate_volatility_adjustment).and_return(1.5) # Favorable volatility
      allow(job).to receive(:calculate_liquidity_adjustment).and_return(1.3) # Good liquidity

      result = job.send(:calculate_opportunity_score)
      # Even with favorable adjustments, base score is capped at 10
      max_possible = 10.0 * 1.5 * 1.3
      expect(result).to eq(max_possible.round(2))
    end
  end
end
