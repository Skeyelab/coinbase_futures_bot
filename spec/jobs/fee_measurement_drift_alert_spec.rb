# frozen_string_literal: true

require "rails_helper"

# Issue #584. FeeTruth computed the right answer and told nobody.
#
# Run against the first two real BIP fills (#486, 2026-07-29):
#
#   perp_taker_drift => {status: "drift", observed_rate: 0.0010175,
#                        model_rate: 0.0003, drift: {relative_drift: 2.3917}}
#
# 239% off the modeled rate. fee_truth.rb:6 predicted exactly this moment —
# "this answers 'is 3 bps right?' the moment real perp fills land". The moment
# arrived and the daily job read the report, iterated by_product_liquidity,
# wrote ProductFee rows, and dropped perp_taker_drift on the floor. No Slack, no
# warning, nothing. CostModel.check_taker_fee_drift! had zero callers.
#
# The 3 bps assumption priced all 12 BIP backtest runs and ADR 0002's venue
# decision. A silent 239% drift on that input is not an observability nicety.
RSpec.describe FeeMeasurementSnapshotJob, "surfaces fee drift (issue #584)" do
  let(:logger) { instance_spy(Logger) }

  # The shape FeeTruth actually returns, with the real #486 numbers.
  def report(drift_status:, observed: 0.0010175179676069318, fills: 2)
    {
      status: "ok",
      fills_examined: 250,
      perp_fills: fills,
      by_product_liquidity: [],
      perp_taker_drift: {
        status: drift_status,
        observed_rate: observed,
        model_rate: 0.0003,
        fills: fills,
        drift: (drift_status == "drift") ? {expected: 0.0003, observed: observed, relative_drift: 2.3917} : nil
      }
    }
  end

  def fee_truth_returning(report)
    double = Class.new do
      def initialize(report) = @report = report

      def call(**) = @report
    end
    double.new(report)
  end

  before do
    allow(SlackNotificationService).to receive(:alert)
    allow(Rails).to receive(:logger).and_return(logger)
  end

  # The tracer: the exact live condition. Something a human sees must happen.
  it "alerts when the measured perp taker rate has drifted from the model" do
    described_class.new.perform(fee_truth: fee_truth_returning(report(drift_status: "drift")))

    expect(SlackNotificationService).to have_received(:alert)
      .with(anything, /fee drift/i, /10\.18 bps.*3\.0 bps|3\.0 bps.*10\.18 bps/im)
  end

  # A verdict without its sample size invites acting on two fills as though it
  # were a settled measurement. It is two fills.
  it "says how many fills the verdict rests on" do
    described_class.new.perform(fee_truth: fee_truth_returning(report(drift_status: "drift", fills: 2)))

    expect(SlackNotificationService).to have_received(:alert).with(anything, anything, /2 fill/i)
  end

  # The alert has to reach the channel humans watch, not the status feed a
  # drifting cost model can sit in unread.
  it "raises it at a level that routes to the alerts channel" do
    described_class.new.perform(fee_truth: fee_truth_returning(report(drift_status: "drift")))

    expect(SlackNotificationService).to have_received(:alert).with(
      satisfy { |level| %w[critical error].include?(level.to_s.downcase) }, anything, anything
    )
  end

  # Silence is the correct output when the model is still true. A job that
  # alerted every night would be muted within a week and then this would be
  # invisible again for a different reason.
  it "stays quiet when the model still matches reality" do
    described_class.new.perform(fee_truth: fee_truth_returning(report(drift_status: "ok")))

    expect(SlackNotificationService).not_to have_received(:alert)
  end

  # Storing measurements is the job's actual purpose and must not become
  # conditional on the drift check.
  it "still returns the report it was given" do
    given = report(drift_status: "drift")

    expect(described_class.new.perform(fee_truth: fee_truth_returning(given))).to eq(given)
  end
end
