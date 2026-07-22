# frozen_string_literal: true

require "rails_helper"

RSpec.describe FundingRateSnapshotJob, type: :job do
  it "delegates to the snapshot service" do
    expect(MarketData::FundingRateSnapshot).to receive(:call)

    described_class.perform_now
  end

  # A swallowed failure is worse than a loud one here: funding history cannot be
  # backfilled, so a silently-skipped hour is permanent data loss.
  it "reports failures to Sentry and re-raises so the run is not silently lost" do
    allow(MarketData::FundingRateSnapshot).to receive(:call).and_raise(Faraday::TimeoutError.new("timeout"))
    allow(Rails.logger).to receive(:error)
    expect(Sentry).to receive(:capture_exception).at_least(:once)

    expect { described_class.perform_now }.to raise_error(Faraday::TimeoutError)
  end

  it "is scheduled on cron so observations accrue without manual runs" do
    expect(Rails.application.config.good_job.cron[:funding_snapshot][:class])
      .to eq("FundingRateSnapshotJob")
  end
end
