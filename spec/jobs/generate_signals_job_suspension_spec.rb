# frozen_string_literal: true

require "rails_helper"

# Issue #411. GenerateSignalsJob runs on cron every 15 minutes over
# Contract.enabled and, outside paper mode, calls execute_order directly. It was
# the only signal path that did NOT consult Trading::SymbolSuspension —
# RealTimeSignalEvaluator and RapidSignalEvaluationJob both do.
#
# That gap matters most for the case it was about to meet: ADR 0002 admits new
# perps as enabled-but-suspended so they accumulate candles without trading. A
# suspended symbol that still reaches execute_order defeats the entire
# no-evidence-inheritance guardrail.
RSpec.describe GenerateSignalsJob do
  subject(:job) { described_class.new }

  let(:strategy) { instance_double(Strategy::MultiTimeframeSignal) }

  before do
    create(:contract, product_id: "BIP-20DEC30-CDE", base_currency: "BTC", enabled: true)
    allow(Trading::StrategyFactory).to receive(:multi_timeframe).and_return(strategy)
    allow(strategy).to receive(:signal).and_return(nil)
    allow(job).to receive(:puts)
  end

  context "when the symbol is suspended" do
    before { Trading::SymbolSuspension.suspend!("BIP-20DEC30-CDE", reason: "data collection only") }

    it "never evaluates the strategy for it" do
      job.perform(equity_usd: 1000.0)

      expect(strategy).not_to have_received(:signal)
    end

    it "never reaches order execution" do
      allow(job).to receive(:paper_trading?).and_return(false)
      allow(job).to receive(:execute_order)

      job.perform(equity_usd: 1000.0)

      expect(job).not_to have_received(:execute_order)
    end
  end

  context "when the symbol is not suspended" do
    it "evaluates the strategy as before" do
      job.perform(equity_usd: 1000.0)

      expect(strategy).to have_received(:signal).with(
        symbol: "BIP-20DEC30-CDE", equity_usd: 1000.0
      )
    end
  end
end
