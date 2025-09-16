# frozen_string_literal: true

require "rails_helper"

RSpec.describe SwingPositionManagementJob, type: :job do
  let(:manager) { instance_double(Trading::SwingPositionManager) }
  let(:logger) { instance_double(Logger) }

  before do
    allow(Rails).to receive(:logger).and_return(logger)
    allow(logger).to receive(:info)
    allow(logger).to receive(:warn)
    allow(logger).to receive(:error)
    allow(Trading::SwingPositionManager).to receive(:new).and_return(manager)
    allow(SentryHelper).to receive(:add_breadcrumb)
    allow(SlackNotificationService).to receive(:alert)
  end

  describe "#perform" do
    context "when positions are approaching expiry" do
      let(:expiring_position) { create(:position, day_trading: false, status: "OPEN") }

      before do
        allow(manager).to receive(:positions_approaching_expiry).and_return([expiring_position])
        allow(manager).to receive(:close_expiring_positions).and_return(1)
        allow(manager).to receive(:positions_exceeding_max_hold).and_return([])
        allow(manager).to receive(:check_swing_tp_sl_triggers).and_return([])
        allow(manager).to receive(:check_swing_risk_limits).and_return({risk_status: "acceptable"})
      end

      it "closes expiring positions and sends notifications" do
        expect(manager).to receive(:close_expiring_positions)
        expect(SlackNotificationService).to receive(:alert).with(
          "warning",
          "Swing Positions Closed - Contract Expiry",
          "Closed 1 swing positions approaching contract expiry."
        )

        subject.perform
      end

      it "logs the operation" do
        expect(logger).to receive(:warn).with("Found 1 swing positions approaching contract expiry")
        expect(logger).to receive(:info).with("Closed 1 positions approaching expiry")

        subject.perform
      end

      it "sends Sentry tracking" do
        expect(SentryHelper).to receive(:add_breadcrumb).with(
          message: "Closing swing positions approaching expiry",
          category: "trading",
          level: "warning",
          data: {operation: "close_expiring_positions", count: 1}
        )

        subject.perform
      end
    end

    context "when positions exceed max hold period" do
      let(:old_position) { create(:position, day_trading: false, status: "OPEN", entry_time: 6.days.ago) }

      before do
        allow(manager).to receive(:positions_approaching_expiry).and_return([])
        allow(manager).to receive(:positions_exceeding_max_hold).and_return([old_position])
        allow(manager).to receive(:close_max_hold_positions).and_return(1)
        allow(manager).to receive(:check_swing_tp_sl_triggers).and_return([])
        allow(manager).to receive(:check_swing_risk_limits).and_return({risk_status: "acceptable"})
      end

      it "closes positions exceeding max hold and sends notifications" do
        expect(manager).to receive(:close_max_hold_positions)
        expect(SlackNotificationService).to receive(:alert).with(
          "warning",
          "Swing Positions Closed - Max Hold Exceeded",
          "Closed 1 swing positions that exceeded maximum holding period."
        )

        subject.perform
      end
    end

    context "when positions hit TP/SL" do
      let(:triggered_position) { create(:position, day_trading: false, status: "OPEN") }
      let(:tp_sl_triggers) { [{position: triggered_position, trigger: "take_profit", current_price: 51_000}] }

      before do
        allow(manager).to receive(:positions_approaching_expiry).and_return([])
        allow(manager).to receive(:positions_exceeding_max_hold).and_return([])
        allow(manager).to receive(:check_swing_tp_sl_triggers).and_return(tp_sl_triggers)
        allow(manager).to receive(:close_tp_sl_positions).and_return(1)
        allow(manager).to receive(:check_swing_risk_limits).and_return({risk_status: "acceptable"})
      end

      it "closes TP/SL triggered positions and sends notifications" do
        expect(manager).to receive(:close_tp_sl_positions)
        expect(SlackNotificationService).to receive(:alert).with(
          "info",
          "Swing Positions Closed - TP/SL Triggered",
          "Closed 1 swing positions that hit take profit or stop loss levels."
        )

        subject.perform
      end
    end

    context "when risk limit violations are detected" do
      let(:risk_violations) do
        {
          risk_status: "violations_detected",
          violations: [
            {type: "max_exposure_exceeded", message: "Total swing position exposure exceeds 30.0% limit"}
          ]
        }
      end

      before do
        allow(manager).to receive(:positions_approaching_expiry).and_return([])
        allow(manager).to receive(:positions_exceeding_max_hold).and_return([])
        allow(manager).to receive(:check_swing_tp_sl_triggers).and_return([])
        allow(manager).to receive(:check_swing_risk_limits).and_return(risk_violations)
      end

      it "sends risk violation alerts" do
        expect(SlackNotificationService).to receive(:alert).with(
          "warning",
          "Swing Trading Risk Violations",
          "Risk limit violations detected: Total swing position exposure exceeds 30.0% limit"
        )

        subject.perform
      end

      it "logs the violations" do
        expect(logger).to receive(:warn).with("Swing trading risk limit violations detected")

        subject.perform
      end
    end

    context "when no actions are needed" do
      before do
        allow(manager).to receive(:positions_approaching_expiry).and_return([])
        allow(manager).to receive(:positions_exceeding_max_hold).and_return([])
        allow(manager).to receive(:check_swing_tp_sl_triggers).and_return([])
        allow(manager).to receive(:check_swing_risk_limits).and_return({risk_status: "acceptable"})
      end

      it "completes successfully without alerts" do
        expect(SlackNotificationService).not_to receive(:alert)
        expect(logger).to receive(:info).with("Starting swing position management job")
        expect(logger).to receive(:info).with("Swing position management job completed successfully")

        subject.perform
      end
    end

    context "when an error occurs" do
      let(:error) { StandardError.new("Test error") }

      before do
        allow(manager).to receive(:positions_approaching_expiry).and_raise(error)
      end

      it "logs the error and sends critical alert" do
        expect(logger).to receive(:error).with("Swing position management job failed: Test error")
        expect(SlackNotificationService).to receive(:alert).with(
          "critical",
          "Swing Position Management Job Failed",
          "Critical swing position management job failed: Test error"
        )

        expect { subject.perform }.to raise_error(StandardError, "Test error")
      end

      it "captures exception in Sentry" do
        expect(Sentry).to receive(:with_scope)

        expect { subject.perform }.to raise_error(StandardError)
      end
    end
  end
end
