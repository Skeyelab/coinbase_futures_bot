# frozen_string_literal: true

require "rails_helper"

RSpec.describe SwingRiskMonitoringJob, type: :job do
  include ActiveSupport::Testing::TimeHelpers

  let(:manager) { instance_double(Trading::SwingPositionManager) }
  let(:logger) { instance_double(Logger) }

  before do
    allow(Rails).to receive(:logger).and_return(logger)
    allow(logger).to receive(:info)
    allow(logger).to receive(:warn)
    allow(logger).to receive(:error)
    allow(Trading::SwingPositionManager).to receive(:new).and_return(manager)
    allow(SlackNotificationService).to receive(:alert)
  end

  describe "#perform" do
    let(:position_summary) do
      {
        total_positions: 2,
        total_exposure: 100_000.0,
        unrealized_pnl: 5000.0,
        positions_by_asset: {"BTC" => {count: 1, exposure: 60_000.0, pnl: 3000.0}},
        risk_metrics: {
          positions_approaching_expiry: 0,
          positions_exceeding_max_hold: 0,
          max_asset_concentration: 0.6,
          avg_hold_time_hours: 48.0
        }
      }
    end

    let(:balance_summary) do
      {
        total_usd_balance: 500_000.0,
        initial_margin: 80_000.0,
        available_margin: 200_000.0
      }
    end

    before do
      allow(manager).to receive(:get_swing_position_summary).and_return(position_summary)
      allow(manager).to receive(:get_swing_balance_summary).and_return(balance_summary)
    end

    context "with active swing positions" do
      it "logs position summary" do
        expect(logger).to receive(:info).with("Starting swing risk monitoring job")
        expect(logger).to receive(:info).with(
          "Swing position summary: 2 positions, Total exposure: $100000.0, Unrealized PnL: $5000.0"
        )
        expect(logger).to receive(:info).with(
          "Margin utilization: 16.0%, Available margin: $200000.0"
        )

        subject.perform
      end

      it "completes successfully" do
        expect(logger).to receive(:info).with("Swing risk monitoring job completed successfully")

        subject.perform
      end
    end

    context "with no swing positions" do
      let(:position_summary) { {total_positions: 0, total_exposure: 0, unrealized_pnl: 0} }

      it "logs no positions message and returns early" do
        expect(logger).to receive(:info).with("No swing positions to monitor")
        expect(manager).to receive(:get_swing_balance_summary).and_return(balance_summary)

        subject.perform
      end
    end

    context "with high margin utilization" do
      let(:balance_summary) do
        {
          total_usd_balance: 100_000.0,
          initial_margin: 85_000.0, # 85% utilization
          available_margin: 15_000.0
        }
      end

      it "sends high margin utilization alert" do
        expect(SlackNotificationService).to receive(:alert).with(
          "warning",
          "High Swing Trading Margin Utilization",
          "Swing trading margin utilization is 85.0%. Available margin: $15000.0"
        )

        subject.perform
      end
    end

    context "with high asset concentration risk" do
      let(:position_summary) do
        {
          total_positions: 1,
          total_exposure: 100_000.0,
          unrealized_pnl: 0,
          risk_metrics: {
            positions_approaching_expiry: 0,
            positions_exceeding_max_hold: 0,
            max_asset_concentration: 0.8 # 80% concentration
          }
        }
      end

      it "sends asset concentration warning" do
        expect(SlackNotificationService).to receive(:alert).with(
          "info",
          "Swing Trading Asset Concentration Warning",
          "Asset concentration risk is 80.0%. Consider diversifying swing positions across more assets."
        )

        subject.perform
      end

      it "logs concentration warning" do
        expect(logger).to receive(:warn).with("High asset concentration risk: 80.0%")

        subject.perform
      end
    end

    context "with positions approaching expiry" do
      let(:position_summary) do
        {
          total_positions: 2,
          total_exposure: 100_000.0,
          unrealized_pnl: 0,
          risk_metrics: {
            positions_approaching_expiry: 1,
            positions_exceeding_max_hold: 0
          }
        }
      end

      it "logs expiry warning" do
        expect(logger).to receive(:warn).with("1 swing positions approaching contract expiry")

        subject.perform
      end
    end

    context "with positions exceeding max hold" do
      let(:position_summary) do
        {
          total_positions: 2,
          total_exposure: 100_000.0,
          unrealized_pnl: 0,
          risk_metrics: {
            positions_approaching_expiry: 0,
            positions_exceeding_max_hold: 1
          }
        }
      end

      it "logs max hold warning" do
        expect(logger).to receive(:warn).with("1 swing positions exceeding maximum hold period")

        subject.perform
      end
    end

    context "with balance API error" do
      let(:balance_summary) { {error: "API connection failed"} }

      it "logs the error and continues" do
        expect(logger).to receive(:error).with("Failed to retrieve balance information: API connection failed")

        subject.perform
      end
    end

    context "during business hours at 10 AM" do
      before do
        travel_to Time.zone.parse("2024-01-15 10:15:00 UTC") # Monday 10:15 AM UTC
      end

      after { travel_back }

      it "sends periodic summary" do
        expect(SlackNotificationService).to receive(:alert).with(
          "info",
          "Daily Swing Trading Summary",
          include("📊 *Swing Trading Summary*")
        )

        subject.perform
      end
    end

    context "outside business hours" do
      before do
        travel_to Time.zone.parse("2024-01-15 18:00:00") # Monday 6 PM
      end

      after { travel_back }

      it "does not send periodic summary" do
        expect(SlackNotificationService).not_to receive(:alert)

        subject.perform
      end
    end

    context "when an error occurs" do
      let(:error) { StandardError.new("Test error") }

      before do
        allow(manager).to receive(:get_swing_position_summary).and_raise(error)
      end

      it "logs the error but does not re-raise" do
        expect(logger).to receive(:error).with("Swing risk monitoring job failed: Test error")

        expect { subject.perform }.not_to raise_error
      end

      it "captures exception in Sentry" do
        expect(Sentry).to receive(:with_scope)

        subject.perform
      end
    end
  end

  describe "#build_summary_text" do
    let(:position_summary) do
      {
        total_positions: 2,
        total_exposure: 150_000.0,
        unrealized_pnl: 7500.0,
        positions_by_asset: {
          "BTC" => {count: 1, pnl: 5000.0},
          "ETH" => {count: 1, pnl: 2500.0}
        },
        risk_metrics: {
          positions_approaching_expiry: 1,
          positions_exceeding_max_hold: 0,
          max_asset_concentration: 0.6
        }
      }
    end

    let(:balance_summary) { {available_margin: 100_000.0} }

    it "builds comprehensive summary text" do
      text = subject.send(:build_summary_text, position_summary, balance_summary)

      expect(text).to include("📊 *Swing Trading Summary*")
      expect(text).to include("• **Positions**: 2")
      expect(text).to include("• **Total Exposure**: $150000.0")
      expect(text).to include("• **Unrealized PnL**: $7500.0")
      expect(text).to include("• **Available Margin**: $100000.0")
      expect(text).to include("• BTC: 1 positions, $5000.0 PnL")
      expect(text).to include("• ETH: 1 positions, $2500.0 PnL")
      expect(text).to include("1 approaching expiry")
      expect(text).to include("High asset concentration (60.0%)")
    end
  end
end
