# frozen_string_literal: true

require "rails_helper"

RSpec.describe PositionCloseJob, type: :job do
  let(:position) { create(:position, :with_tp_sl) }
  let(:logger) { instance_double(ActiveSupport::Logger) }
  let(:positions_service) { instance_double(Trading::CoinbasePositions) }
  let(:lifecycle) { instance_double(Trading::PositionLifecycle) }

  def success_result(close_price: 50_001.0)
    Trading::PositionLifecycle::Result.new(success: true, close_price: close_price, reason: nil, fallback: false)
  end

  def failure_result
    Trading::PositionLifecycle::Result.new(success: false, close_price: nil, reason: nil, fallback: false)
  end

  before do
    allow(Rails).to receive(:logger).and_return(logger)
    allow(logger).to receive(:info)
    allow(logger).to receive(:warn)
    allow(logger).to receive(:error)
    allow(Trading::CoinbasePositions).to receive(:new).with(logger: logger).and_return(positions_service)
    allow(Trading::PositionLifecycle).to receive(:new).with(positions_service: positions_service, logger: logger).and_return(lifecycle)
  end

  describe "#perform" do
    context "with successful position closure" do
      before do
        allow(lifecycle).to receive(:close) { |pos, reason:|
          pos.force_close!(50_001.0, reason)
          success_result
        }
      end

      it "closes an open position successfully" do
        described_class.perform_now(position_id: position.id, reason: "manual_close")
        expect(position.reload.status).to eq("CLOSED")
        expect(position.close_time).to be_present
      end

      it "logs successful closure" do
        expect(logger).to receive(:info).with(
          "[PCJ] Closing position #{position.id} (#{position.product_id}) - Reason: manual_close"
        )
        expect(logger).to receive(:info).with(
          "[PCJ] Successfully closed position #{position.id}: manual_close"
        )
        described_class.perform_now(position_id: position.id, reason: "manual_close")
      end

      it "sends closure alert" do
        described_class.perform_now(position_id: position.id, reason: "take_profit")
        expect(logger).to have_received(:info).with(
          match(/\[ALERT\] CLOSED: #{position.side} #{position.size} contracts of #{position.product_id}/)
        )
      end

      it "handles different closure reasons" do
        %w[manual_close take_profit stop_loss time_limit market_conditions].each do |reason|
          pos = create(:position)
          allow(lifecycle).to receive(:close) { |p, reason:|
            p.force_close!(50_001.0, reason)
            success_result
          }
          expect(logger).to receive(:info).with(
            "[PCJ] Closing position #{pos.id} (#{pos.product_id}) - Reason: #{reason}"
          )
          described_class.perform_now(position_id: pos.id, reason: reason)
        end
      end
    end

    context "with failed position closure (no price available)" do
      before do
        allow(lifecycle).to receive(:close).and_return(failure_result)
      end

      it "logs failure and does not update position status" do
        expect(logger).to receive(:error).with(
          "[PCJ] Failed to close position #{position.id}"
        )
        described_class.perform_now(position_id: position.id, reason: "manual_close")
        position.reload
        expect(position.status).to eq("OPEN")
        expect(position.close_time).to be_nil
      end

      context "with critical closure reasons" do
        %w[stop_loss take_profit time_limit].each do |critical_reason|
          it "retries #{critical_reason} closure after failure" do
            expect(logger).to receive(:info).with("[PCJ] Retrying critical position closure")
            allow(PositionCloseJob).to receive_message_chain(:set, :perform_later)
            described_class.perform_now(position_id: position.id, reason: critical_reason)
          end
        end
      end

      context "with non-critical closure reasons" do
        it "does not retry manual_close closure after failure" do
          expect(PositionCloseJob).not_to receive(:set)
          described_class.perform_now(position_id: position.id, reason: "manual_close")
        end
      end
    end

    context "when position does not exist" do
      it "handles ActiveRecord::RecordNotFound gracefully" do
        expect(logger).to receive(:warn).with(
          "[PCJ] Position 999999 not found - may have been closed already"
        )
        scope_double = double("scope").as_null_object
        allow(Sentry).to receive(:with_scope).and_yield(scope_double)
        allow(Sentry).to receive(:capture_exception)
        allow(SentryHelper).to receive(:add_breadcrumb)
        expect {
          described_class.perform_now(position_id: 999999, reason: "manual_close")
        }.not_to raise_error
      end
    end

    context "when position is already closed" do
      let(:closed_position) { create(:position, :closed) }

      it "returns early without calling lifecycle" do
        expect(lifecycle).not_to receive(:close)
        expect(logger).to receive(:info).with(
          "[PCJ] Closing position #{closed_position.id} (#{closed_position.product_id}) - Reason: manual_close"
        )
        described_class.perform_now(position_id: closed_position.id, reason: "manual_close")
      end
    end

    context "when unexpected errors occur" do
      before do
        allow(lifecycle).to receive(:close).and_raise(StandardError, "Network timeout")
      end

      it "logs the error" do
        expect(logger).to receive(:error).with(
          "[PCJ] Error closing position #{position.id}: Network timeout"
        )
        expect {
          described_class.perform_now(position_id: position.id, reason: "manual_close")
        }.not_to raise_error
      end

      context "with critical closure reasons" do
        it "retries critical closures after errors" do
          expect(logger).to receive(:info).with("[PCJ] Retrying critical position closure")
          allow(PositionCloseJob).to receive_message_chain(:set, :perform_later)
          described_class.perform_now(position_id: position.id, reason: "stop_loss")
        end
      end

      context "with non-critical closure reasons" do
        it "does not retry non-critical closures after errors" do
          expect(PositionCloseJob).not_to receive(:set)
          described_class.perform_now(position_id: position.id, reason: "manual_close")
        end
      end
    end
  end

  describe "private methods" do
    let(:job_instance) { described_class.new }

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

      it "handles emergency closure with retry logic when lifecycle fails" do
        allow(lifecycle).to receive(:close).and_return(failure_result)
        allow(PositionCloseJob).to receive_message_chain(:set, :perform_later)
        expect(logger).to receive(:info).with("[PCJ] Retrying critical position closure")
        described_class.perform_now(position_id: emergency_position.id, reason: "time_limit")
      end
    end

    context "high-frequency closure scenarios" do
      it "handles rapid successive closures" do
        positions = create_list(:position, 3, :with_tp_sl)
        positions.each do |pos|
          allow(lifecycle).to receive(:close) { |p, reason:|
            p.force_close!(50_001.0, reason)
            success_result
          }
          described_class.perform_now(position_id: pos.id, reason: "take_profit")
          expect(pos.reload.status).to eq("CLOSED")
        end
      end
    end

    context "different position types" do
      it "handles BTC futures position closure" do
        btc_position = create(:position, product_id: "BIT-29AUG25-CDE")
        allow(lifecycle).to receive(:close) { |p, reason:|
          p.force_close!(50_001.0, reason)
          success_result
        }
        described_class.perform_now(position_id: btc_position.id, reason: "take_profit")
        expect(btc_position.reload.status).to eq("CLOSED")
      end

      it "handles ETH futures position closure" do
        eth_position = create(:position, :eth)
        allow(lifecycle).to receive(:close) { |p, reason:|
          p.force_close!(3_001.0, reason)
          success_result
        }
        described_class.perform_now(position_id: eth_position.id, reason: "stop_loss")
        expect(eth_position.reload.status).to eq("CLOSED")
      end

      it "handles short position closure" do
        short_position = create(:position, :short, :with_tp_sl)
        allow(lifecycle).to receive(:close) { |p, reason:|
          p.force_close!(50_001.0, reason)
          success_result
        }
        described_class.perform_now(position_id: short_position.id, reason: "manual_close")
        expect(short_position.reload.status).to eq("CLOSED")
      end
    end

    context "market condition scenarios" do
      it "schedules retry when lifecycle fails for critical close" do
        volatile_position = create(:position, size: 5.0)
        allow(lifecycle).to receive(:close).and_return(failure_result)
        allow(PositionCloseJob).to receive_message_chain(:set, :perform_later)
        described_class.perform_now(position_id: volatile_position.id, reason: "stop_loss")
        expect(logger).to have_received(:info).with("[PCJ] Retrying critical position closure")
      end
    end

    context "risk management scenarios" do
      it "handles stop loss triggered closure" do
        risky_position = create(:position, stop_loss: 49_000.0, entry_price: 50_000.0)
        allow(lifecycle).to receive(:close) { |p, reason:|
          p.force_close!(49_000.0, reason)
          success_result(close_price: 49_000.0)
        }
        described_class.perform_now(position_id: risky_position.id, reason: "stop_loss")
        expect(risky_position.reload.status).to eq("CLOSED")
      end

      it "handles take profit triggered closure" do
        profitable_position = create(:position, take_profit: 51_000.0, entry_price: 50_000.0)
        allow(lifecycle).to receive(:close) { |p, reason:|
          p.force_close!(51_000.0, reason)
          success_result(close_price: 51_000.0)
        }
        described_class.perform_now(position_id: profitable_position.id, reason: "take_profit")
        expect(profitable_position.reload.status).to eq("CLOSED")
      end
    end
  end

  describe "performance and edge cases" do
    context "with large position sizes" do
      it "handles large position closure" do
        large_position = create(:position, size: 100.0)
        allow(lifecycle).to receive(:close) { |p, reason:|
          p.force_close!(50_001.0, reason)
          success_result
        }
        described_class.perform_now(position_id: large_position.id, reason: "manual_close")
        expect(large_position.reload.status).to eq("CLOSED")
      end
    end

    context "with precision edge cases" do
      it "handles fractional position sizes" do
        fractional_position = create(:position, size: 0.001)
        allow(lifecycle).to receive(:close) { |p, reason:|
          p.force_close!(50_001.0, reason)
          success_result
        }
        described_class.perform_now(position_id: fractional_position.id, reason: "take_profit")
        expect(fractional_position.reload.status).to eq("CLOSED")
      end
    end

    context "with concurrent closure attempts" do
      it "handles race conditions gracefully" do
        concurrent_position = create(:position)
        concurrent_position.update!(status: "CLOSED", close_time: Time.current)
        expect(lifecycle).not_to receive(:close)
        described_class.perform_now(position_id: concurrent_position.id, reason: "manual_close")
      end
    end
  end
end
