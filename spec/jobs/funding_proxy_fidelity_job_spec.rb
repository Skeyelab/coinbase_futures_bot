# frozen_string_literal: true

require "rails_helper"

# Daily proxy-fidelity cross-validation (#568 caveat 1, #572): the funding-skew
# strategy trades a basis PROXY (r = 0.58-0.77 against real funding snapshots),
# so backtest-vs-live parity depends on the proxy staying faithful. This job
# re-runs the correlation daily for every configured funding-skew pairing and
# warns loudly — log + Slack — when r degrades or the overlap is too thin to
# judge.
RSpec.describe FundingProxyFidelityJob, type: :job do
  let(:job) { described_class.new }
  let(:proxy) { instance_double(Signals::FundingProxy) }

  def stub_selection(symbols)
    allow(Trading::StrategySelection).to receive(:default)
      .and_return(Trading::StrategySelection.new({"symbols" => symbols}))
  end

  let(:bip_entry) do
    {"strategy" => "FundingSkewContrarian", "enabled" => true,
     "params" => {"window" => 168, "spot_symbol" => "BTC-USD"}}
  end

  before do
    allow(SlackNotificationService).to receive(:alert)
    allow(Signals::FundingProxy).to receive(:new).and_return(proxy)
  end

  it "does nothing when no funding-skew pairing is configured" do
    stub_selection({})

    job.perform

    expect(Signals::FundingProxy).not_to have_received(:new)
    expect(SlackNotificationService).not_to have_received(:alert)
  end

  it "cross-validates the configured pairing over the trailing window" do
    stub_selection("BIP-FID-CDE" => bip_entry)
    allow(proxy).to receive(:correlation_with_funding).and_return({n: 200, r: 0.72})

    job.perform

    expect(Signals::FundingProxy).to have_received(:new)
      .with(perp_symbol: "BIP-FID-CDE", spot_symbol: "BTC-USD", window: 168)
    expect(proxy).to have_received(:correlation_with_funding)
      .with(from: kind_of(Time), to: kind_of(Time))
    expect(SlackNotificationService).not_to have_received(:alert)
  end

  it "still validates a pairing whose entry is not yet enabled (pre-flip check)" do
    stub_selection("BIP-FID-CDE" => bip_entry.merge("enabled" => false))
    allow(proxy).to receive(:correlation_with_funding).and_return({n: 200, r: 0.72})

    job.perform

    expect(proxy).to have_received(:correlation_with_funding)
  end

  it "alerts error when r drops below the floor" do
    stub_selection("BIP-FID-CDE" => bip_entry)
    allow(proxy).to receive(:correlation_with_funding).and_return({n: 200, r: 0.41})
    allow(Rails.logger).to receive(:error).and_call_original

    job.perform

    expect(SlackNotificationService).to have_received(:alert)
      .with("error", /[Ff]unding proxy/, hash_including(symbol: "BIP-FID-CDE", r: 0.41, n: 200))
    expect(Rails.logger).to have_received(:error).with(/FundingProxyFidelity/)
  end

  it "treats a nil r (no variance) as a fidelity failure" do
    stub_selection("BIP-FID-CDE" => bip_entry)
    allow(proxy).to receive(:correlation_with_funding).and_return({n: 200, r: nil})

    job.perform

    expect(SlackNotificationService).to have_received(:alert)
      .with("error", /[Ff]unding proxy/, hash_including(symbol: "BIP-FID-CDE"))
  end

  it "warns when the snapshot overlap is too thin to judge fidelity" do
    stub_selection("BIP-FID-CDE" => bip_entry)
    allow(proxy).to receive(:correlation_with_funding).and_return({n: 5, r: 0.9})
    allow(Rails.logger).to receive(:warn).and_call_original

    job.perform

    expect(SlackNotificationService).to have_received(:alert)
      .with("warning", /[Ff]unding proxy/, hash_including(symbol: "BIP-FID-CDE", n: 5))
    expect(Rails.logger).to have_received(:warn).with(/FundingProxyFidelity/)
  end

  it "is registered on the daily cron" do
    entry = Rails.application.config.good_job.cron[:funding_proxy_fidelity]

    expect(entry).not_to be_nil
    expect(entry[:class]).to eq("FundingProxyFidelityJob")
  end
end
