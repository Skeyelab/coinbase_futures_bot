# frozen_string_literal: true

require "rails_helper"

# The 15m signal cron resolves each pair through the same
# Trading::StrategyFactory.for_symbol site as the evaluator and the execution
# job (#303) — one resolution site, no per-job divergence.
RSpec.describe GenerateSignalsJob, "declarative selection", type: :job do
  let(:job) { described_class.new }
  let!(:contract) { create(:contract, enabled: true, product_id: "BIP-GEN-CDE") }
  let(:fsc) { instance_double(Strategy::FundingSkewContrarian, signal: nil) }

  before do
    Rails.cache.clear
    allow(job).to receive(:puts)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("PAPER_TRADING_MODE").and_return("true")
    allow(Trading::StrategySelection).to receive(:default)
      .and_return(Trading::StrategySelection.new({"symbols" => {
        "BIP-GEN-CDE" => {
          "strategy" => "FundingSkewContrarian",
          "params" => {"entry_z" => 2.0, "spot_symbol" => "BTC-USD"}
        }
      }}))
    allow(Strategy::FundingSkewContrarian).to receive(:new).and_return(fsc)
  end

  it "consults the configured strategy for a configured pair" do
    job.perform(equity_usd: 10_000.0)

    expect(Strategy::FundingSkewContrarian).to have_received(:new)
      .with(hash_including(entry_z: 2.0, spot_symbol: "BTC-USD"))
    expect(fsc).to have_received(:signal).with(symbol: "BIP-GEN-CDE", equity_usd: 10_000.0)
  end

  it "keeps unconfigured pairs on the default strategy" do
    create(:contract, enabled: true, product_id: "BIT-GEN-CDE")
    mts = instance_double(Strategy::MultiTimeframeSignal, signal: nil)
    allow(Strategy::MultiTimeframeSignal).to receive(:new).and_return(mts)

    job.perform(equity_usd: 10_000.0)

    expect(mts).to have_received(:signal).with(symbol: "BIT-GEN-CDE", equity_usd: 10_000.0)
  end
end
