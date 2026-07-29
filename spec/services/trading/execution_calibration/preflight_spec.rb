# frozen_string_literal: true

require "rails_helper"

# Issue #486's four blocking preconditions, asserted IN CODE before any order is
# placed. A precondition that is only written down is not a precondition.
RSpec.describe Trading::ExecutionCalibration::Preflight do
  let(:product_id) { "BIP-20DEC30-CDE" }

  subject(:preflight) { described_class.new(product_id: product_id) }

  before do
    BotRuntimeStat.delete_all
    Position.destroy_all
    Contract.where(product_id: product_id).delete_all
    create(:contract, product_id: product_id, base_currency: "BTC")
    allow(Trading::EquityAssertion).to receive(:verify!).and_return({sizing: 1000.0, actual: 1000.0})
  end

  it "passes when every precondition holds" do
    expect(preflight.failures).to be_empty
    expect(preflight).to be_satisfied
  end

  describe "precondition 2 — the cumulative-loss cap" do
    it "fails when the cumulative cap exceeds the $150 authorized loss" do
      allow(Trading::LossLimits).to receive(:live_cumulative_cap).and_return(500.0)

      expect(preflight.failures.join).to include("cumulative loss cap")
      expect(preflight.failures.join).to include("150")
    end

    it "fails when no cumulative cap is set at all" do
      allow(Trading::LossLimits).to receive(:live_cumulative_cap).and_return(0.0)

      expect(preflight.failures.join).to include("cumulative loss cap")
    end

    # $100 (the LOSS_CAP_CUMULATIVE_USD default) is tighter than #486's $150, so
    # it trips first. That is fine — the assertion is <= 150, not == 150.
    it "accepts a cap tighter than the authorized loss" do
      allow(Trading::LossLimits).to receive(:live_cumulative_cap).and_return(100.0)

      expect(preflight.failures).to be_empty
    end
  end

  describe "precondition 3 — the equity assertion" do
    it "fails, naming the divergence, when sizing equity disagrees with the balance" do
      allow(Trading::EquityAssertion).to receive(:verify!)
        .and_raise(Trading::EquityAssertion::Divergence, "SIGNAL_EQUITY_USD is $10000.00 but the account holds $1000.00")

      expect(preflight.failures.join).to include("SIGNAL_EQUITY_USD")
    end
  end

  describe "precondition 4 — BIP pinned to 1 contract / 1 concurrent" do
    it "fails when the contract is not pinned to a single contract" do
      allow(Trading::AssetSizing).to receive(:for_product)
        .and_return(Trading::AssetSizing::Params.new(contract_size_usd: 659.0, max_contracts: 5, max_concurrent: 1))

      expect(preflight.failures.join).to include("max_contracts")
    end

    it "fails when the contract is not pinned to a single concurrent position" do
      allow(Trading::AssetSizing).to receive(:for_product)
        .and_return(Trading::AssetSizing::Params.new(contract_size_usd: 659.0, max_contracts: 1, max_concurrent: 2))

      expect(preflight.failures.join).to include("max_concurrent")
    end
  end

  describe "operational preconditions" do
    it "refuses to start while a position is already open on the instrument" do
      create(:position, product_id: product_id, status: "OPEN")

      expect(preflight.failures.join).to include("already OPEN")
    end

    it "refuses to start while trading is halted" do
      TradingHalt.halt_for_risk!(reason: "prior breach")

      expect(preflight.failures.join).to include("halted")
    end
  end

  # Every failure must name what is missing, so an operator reading the refusal
  # knows what to fix rather than what to re-run.
  it "reports every unmet precondition at once rather than stopping at the first" do
    allow(Trading::LossLimits).to receive(:live_cumulative_cap).and_return(500.0)
    create(:position, product_id: product_id, status: "OPEN")

    expect(preflight.failures.size).to be >= 2
  end
end
