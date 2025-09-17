# frozen_string_literal: true

require "rails_helper"

RSpec.describe PositionCloseJob, type: :job do
  let(:position) { create(:position, :with_tp_sl) }
  let(:logger) { instance_double(ActiveSupport::Logger) }
  let(:positions_service) { instance_double(Trading::CoinbasePositions) }

  before do
    allow(Rails).to receive(:logger).and_return(logger)
    allow(logger).to receive(:info)
    allow(logger).to receive(:warn)
    allow(logger).to receive(:error)
    allow(Trading::CoinbasePositions).to receive(:new).with(logger: logger).and_return(positions_service)
  end

  describe "#perform" do
    context "with successful position closure" do
      let(:successful_result) do
        {
          success: true,
          order_id: "order_123",
          pnl: 150.0
        }
      end

      before do
        allow(positions_service).to receive(:close_position).and_return(successful_result)
      end

      it "closes an open position successfully" do
        expect(positions_service).to receive(:close_position).with(
          product_id: position.product_id,
          size: position.size
        )

        described_class.perform_now(
          position_id: position.id,
          reason: "manual_close"
        )

        position.reload
        expect(position.status).to eq("CLOSED")
        expect(position.close_time).to be_present
        expect(position.pnl).to eq(150.0)
      end

      it "logs successful closure" do
        expect(logger).to receive(:info).with(
          "[PCJ] Closing position #{position.id} (#{position.product_id}) - Reason: manual_close"
        )
        expect(logger).to receive(:info).with(
          "[PCJ] Successfully closed position #{position.id}: manual_close"
        )

        described_class.perform_now(
          position_id: position.id,
          reason: "manual_close"
        )
      end

      it "sends closure alert" do
        described_class.perform_now(
          position_id: position.id,
          reason: "take_profit"
        )

        position.reload
        expect(logger).to have_received(:info).with(
          match(/\[ALERT\] CLOSED: #{position.side} #{position.size} contracts of #{position.product_id}/)
        )
      end

      it "handles different closure reasons" do
        reasons = %w[manual_close take_profit stop_loss time_limit market_conditions]

        reasons.each do |reason|
          pos = create(:position)
          allow(positions_service).to receive(:close_position).and_return(successful_result)

          expect(logger).to receive(:info).with(
            "[PCJ] Closing position #{pos.id} (#{pos.product_id}) - Reason: #{reason}"
          )

          described_class.perform_now(
            position_id: pos.id,
            reason: reason
          )
        end
      end
    end

    context "with failed position closure" do
      let(:failed_result) do
        {
          success: false,
          error: "Insufficient margin"
        }
      end

      before do
        allow(positions_service).to receive(:close_position).and_return(failed_result)
      end

      it "logs failure and does not update position status" do
        expect(logger).to receive(:error).with(
          "[PCJ] Failed to close position #{position.id}: Insufficient margin"
        )

        described_class.perform_now(
          position_id: position.id,
          reason: "manual_close"
        )

        position.reload
        expect(position.status).to eq("OPEN")
        expect(position.close_time).to be_nil
      end

      context "with critical closure reasons" do
        %w[stop_loss take_profit time_limit].each do |critical_reason|
          it "retries #{critical_reason} closure after failure" do
            expect(logger).to receive(:info).with(
              "[PCJ] Retrying critical position closure in 30 seconds"
            )

            # Mock the job scheduling without detailed verification
            allow(PositionCloseJob).to receive_message_chain(:set, :perform_later)

            described_class.perform_now(
              position_id: position.id,
              reason: critical_reason
            )
          end
        end
      end

      context "with non-critical closure reasons" do
        it "does not retry manual_close closure after failure" do
          expect(PositionCloseJob).not_to receive(:set)

          described_class.perform_now(
            position_id: position.id,
            reason: "manual_close"
          )
        end
      end
    end

    context "when position does not exist" do
      it "handles ActiveRecord::RecordNotFound gracefully" do
        expect(logger).to receive(:warn).with(
          "[PCJ] Position 999999 not found - may have been closed already"
        )

        # Disable Sentry completely for this test
        scope_double = double("scope").as_null_object
        allow(Sentry).to receive(:with_scope).and_yield(scope_double)
        allow(Sentry).to receive(:capture_exception)
        allow(SentryHelper).to receive(:add_breadcrumb)

        expect {
          described_class.perform_now(
            position_id: 999999,
            reason: "manual_close"
          )
        }.not_to raise_error
      end
    end

    context "when position is already closed" do
      let(:closed_position) { create(:position, :closed) }

      it "returns early without attempting closure" do
        expect(positions_service).not_to receive(:close_position)

        expect(logger).to receive(:info).with(
          "[PCJ] Closing position #{closed_position.id} (#{closed_position.product_id}) - Reason: manual_close"
        )

        described_class.perform_now(
          position_id: closed_position.id,
          reason: "manual_close"
        )
      end
    end

    context "when unexpected errors occur" do
      before do
        allow(positions_service).to receive(:close_position).and_raise(StandardError, "Network timeout")
      end

      it "logs the error" do
        expect(logger).to receive(:error).with(
          "[PCJ] Error closing position #{position.id}: Network timeout"
        )

        expect {
          described_class.perform_now(
            position_id: position.id,
            reason: "manual_close"
          )
        }.not_to raise_error
      end

      context "with critical closure reasons" do
        it "retries critical closures after errors" do
          expect(logger).to receive(:info).with(
            "[PCJ] Retrying critical position closure due to error"
          )

          # Mock the job scheduling without detailed verification
          allow(PositionCloseJob).to receive_message_chain(:set, :perform_later)

          described_class.perform_now(
            position_id: position.id,
            reason: "stop_loss"
          )
        end
      end

      context "with non-critical closure reasons" do
        it "does not retry non-critical closures after errors" do
          expect(PositionCloseJob).not_to receive(:set)

          described_class.perform_now(
            position_id: position.id,
            reason: "manual_close"
          )
        end
      end
    end
  end

  describe "private methods" do
    let(:job_instance) { described_class.new }

    describe "#calculate_pnl" do
      it "extracts PnL from successful result" do
        result = {pnl: 250.0}
        expect(job_instance.send(:calculate_pnl, result)).to eq(250.0)
      end

      it "returns 0.0 when PnL is not present" do
        result = {success: true}
        expect(job_instance.send(:calculate_pnl, result)).to eq(0.0)
      end

      it "handles nil result" do
        expect(job_instance.send(:calculate_pnl, {})).to eq(0.0)
      end
    end

    describe "#send_closure_alert" do
      before do
        job_instance.instance_variable_set(:@position, position)
        job_instance.instance_variable_set(:@reason, "take_profit")
        job_instance.instance_variable_set(:@logger, logger)
      end

      it "logs closure alert with profit" do
        position.update!(pnl: 100.0)

        expect(logger).to receive(:info).with(
          "[ALERT] CLOSED: #{position.side} #{position.size} contracts of #{position.product_id} - TAKE_PROFIT - PROFIT: $100.0"
        )

        job_instance.send(:send_closure_alert)
      end

      it "logs closure alert with loss" do
        position.update!(pnl: -50.0)

        expect(logger).to receive(:info).with(
          "[ALERT] CLOSED: #{position.side} #{position.size} contracts of #{position.product_id} - TAKE_PROFIT - LOSS: $-50.0"
        )

        job_instance.send(:send_closure_alert)
      end

      it "logs closure alert with nil PnL" do
        position.update!(pnl: nil)

        expect(logger).to receive(:info).with(
          "[ALERT] CLOSED: #{position.side} #{position.size} contracts of #{position.product_id} - TAKE_PROFIT - LOSS: $0"
        )

        job_instance.send(:send_closure_alert)
      end
    end

    describe "#extract_asset_from_product_id" do
      it "extracts BTC from BIT prefixed product" do
        result = job_instance.send(:extract_asset_from_product_id, "BIT-29AUG25-CDE")
        expect(result).to eq("BTC")
      end

      it "extracts ETH from ET prefixed product" do
        result = job_instance.send(:extract_asset_from_product_id, "ET-29AUG25-CDE")
        expect(result).to eq("ETH")
      end

      it "extracts first part for other products" do
        result = job_instance.send(:extract_asset_from_product_id, "SOL-USD")
        expect(result).to eq("SOL")
      end

      it "handles complex product IDs" do
        result = job_instance.send(:extract_asset_from_product_id, "AVAX-PERP-INTX")
        expect(result).to eq("AVAX")
      end
    end
  end

  describe "job configuration" do
    it "uses the critical queue" do
      expect(described_class.queue_name).to eq("critical")
    end

    it "inherits from ApplicationJob" do
      expect(described_class.superclass).to eq(ApplicationJob)
    end
  end

  describe "integration scenarios" do
    context "emergency position closure" do
      let(:emergency_position) { create(:position, entry_time: 25.hours.ago, day_trading: true) }

      it "handles emergency closure with retry logic" do
        allow(positions_service).to receive(:close_position).and_return({
          success: false,
          error: "Market volatility"
        })

        expect(logger).to receive(:info).with(
          "[PCJ] Retrying critical position closure in 30 seconds"
        )

        described_class.perform_now(
          position_id: emergency_position.id,
          reason: "time_limit"
        )
      end
    end

    context "high-frequency closure scenarios" do
      it "handles rapid successive closures" do
        positions = create_list(:position, 3, :with_tp_sl)

        positions.each do |pos|
          allow(positions_service).to receive(:close_position).and_return({
            success: true,
            pnl: rand(50..200)
          })

          described_class.perform_now(
            position_id: pos.id,
            reason: "take_profit"
          )

          pos.reload
          expect(pos.status).to eq("CLOSED")
        end
      end
    end

    context "different position types" do
      it "handles BTC futures position closure" do
        btc_position = create(:position, product_id: "BIT-29AUG25-CDE")
        allow(positions_service).to receive(:close_position).and_return({success: true, pnl: 100.0})

        described_class.perform_now(
          position_id: btc_position.id,
          reason: "take_profit"
        )

        btc_position.reload
        expect(btc_position.status).to eq("CLOSED")
      end

      it "handles ETH futures position closure" do
        eth_position = create(:position, :eth)
        allow(positions_service).to receive(:close_position).and_return({success: true, pnl: 50.0})

        described_class.perform_now(
          position_id: eth_position.id,
          reason: "stop_loss"
        )

        eth_position.reload
        expect(eth_position.status).to eq("CLOSED")
      end

      it "handles short position closure" do
        short_position = create(:position, :short, :with_tp_sl)
        allow(positions_service).to receive(:close_position).and_return({success: true, pnl: -25.0})

        described_class.perform_now(
          position_id: short_position.id,
          reason: "manual_close"
        )

        short_position.reload
        expect(short_position.status).to eq("CLOSED")
        expect(short_position.pnl).to eq(-25.0)
      end
    end

    context "market condition scenarios" do
      it "handles closure during volatile market conditions" do
        volatile_position = create(:position, size: 5.0)

        # Simulate volatile market with intermittent failures
        call_count = 0
        allow(positions_service).to receive(:close_position) do
          call_count += 1
          if call_count == 1
            {success: false, error: "Market volatility - please retry"}
          else
            {success: true, pnl: 75.0}
          end
        end

        # First attempt fails
        described_class.perform_now(
          position_id: volatile_position.id,
          reason: "stop_loss"
        )

        # Verify retry was scheduled
        expect(logger).to have_received(:info).with(
          "[PCJ] Retrying critical position closure in 30 seconds"
        )
      end
    end

    context "risk management scenarios" do
      it "handles stop loss triggered closure" do
        risky_position = create(:position, stop_loss: 49000.0, entry_price: 50000.0)
        allow(positions_service).to receive(:close_position).and_return({
          success: true,
          pnl: -1000.0
        })

        described_class.perform_now(
          position_id: risky_position.id,
          reason: "stop_loss"
        )

        risky_position.reload
        expect(risky_position.status).to eq("CLOSED")
        expect(risky_position.pnl).to eq(-1000.0)
      end

      it "handles take profit triggered closure" do
        profitable_position = create(:position, take_profit: 51000.0, entry_price: 50000.0)
        allow(positions_service).to receive(:close_position).and_return({
          success: true,
          pnl: 1000.0
        })

        described_class.perform_now(
          position_id: profitable_position.id,
          reason: "take_profit"
        )

        profitable_position.reload
        expect(profitable_position.status).to eq("CLOSED")
        expect(profitable_position.pnl).to eq(1000.0)
      end
    end
  end

  describe "performance and edge cases" do
    context "with large position sizes" do
      it "handles large position closure" do
        large_position = create(:position, size: 100.0)
        allow(positions_service).to receive(:close_position).and_return({
          success: true,
          pnl: 5000.0
        })

        described_class.perform_now(
          position_id: large_position.id,
          reason: "manual_close"
        )

        large_position.reload
        expect(large_position.status).to eq("CLOSED")
      end
    end

    context "with precision edge cases" do
      it "handles fractional position sizes" do
        fractional_position = create(:position, size: 0.001)
        allow(positions_service).to receive(:close_position).and_return({
          success: true,
          pnl: 0.5
        })

        described_class.perform_now(
          position_id: fractional_position.id,
          reason: "take_profit"
        )

        fractional_position.reload
        expect(fractional_position.status).to eq("CLOSED")
      end
    end

    context "with concurrent closure attempts" do
      it "handles race conditions gracefully" do
        concurrent_position = create(:position)

        # Simulate concurrent closure by having the position already closed
        concurrent_position.update!(status: "CLOSED", close_time: Time.current)

        expect(positions_service).not_to receive(:close_position)

        described_class.perform_now(
          position_id: concurrent_position.id,
          reason: "manual_close"
        )
      end
    end
  end
end
