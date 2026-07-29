# frozen_string_literal: true

require "rails_helper"

# Declarative strategy selection on the REAL execution path (#303/#568).
#
# Selection is keyed on the CONTRACT that will trade, not the tick product:
# a spot BTC-USD tick resolves to the BIP perp (#390), and if BIP is
# configured for FundingSkewContrarian then an MTS signal from the spot feed
# must not open BIP positions — that would contaminate the #376 gate-2a
# sample with another strategy's trades (the #479/#504 divergence class).
RSpec.describe RapidSignalEvaluationJob, "declarative selection", type: :job do
  let(:job) { described_class.new }
  let(:tick_product) { "BTC-USD" }
  let(:contract_id) { "BIP-20DEC30-CDE" }

  let(:fsc) { instance_double(Strategy::FundingSkewContrarian) }
  let(:contract_manager) { instance_double(MarketData::FuturesContractManager) }
  let(:positions_service) { instance_double(Trading::CoinbasePositions) }

  let(:fsc_signal) do
    {side: :long, price: 100_000.0, quantity: 1,
     tp: 100_500.0, sl: 99_000.0, confidence: 22.0}
  end

  def stub_selection(symbols)
    allow(Trading::StrategySelection).to receive(:default)
      .and_return(Trading::StrategySelection.new({"symbols" => symbols}))
  end

  let(:bip_entry) do
    {"strategy" => "FundingSkewContrarian",
     "min_confidence" => 0,
     "params" => {"entry_z" => 2.0, "exit_z" => 0.5, "window" => 168,
                  "stop" => 0.01, "spot_symbol" => "BTC-USD"}}
  end

  before do
    # These specs are about STRATEGY SELECTION, not about whether the symbol has
    # earned the right to trade. The cost gate (#575, ADR 0006 decision 3) sits
    # upstream of selection and refuses any symbol without a passing
    # walk-forward verdict, so without this every selection example would fail
    # for a reason it is not testing.
    pass_cost_gate!(contract_id)
    allow(MarketData::FuturesContractManager).to receive(:new).and_return(contract_manager)
    allow(contract_manager).to receive(:best_available_contract).with("BTC").and_return(contract_id)
    allow(Trading::CoinbasePositions).to receive(:new).and_return(positions_service)
    allow(positions_service).to receive(:open_position).and_return({"success" => true})
    allow(Trading::NotionalCap).to receive(:allows?).and_return(true)
    allow(Strategy::FundingSkewContrarian).to receive(:new).and_return(fsc)
    allow(fsc).to receive(:signal).and_return(fsc_signal)
  end

  def perform!
    job.perform(product_id: tick_product, current_price: 100_000.0, asset: "BTC", day_trading: false)
  end

  context "when the resolved contract has an enabled funding-skew entry" do
    before { stub_selection(contract_id => bip_entry) }

    it "builds the configured strategy with the selection's frozen params" do
      perform!

      expect(Strategy::FundingSkewContrarian).to have_received(:new)
        .with(hash_including(entry_z: 2.0, exit_z: 0.5, window: 168,
          stop: 0.01, spot_symbol: "BTC-USD"))
    end

    it "evaluates the CONTRACT's symbol, not the spot tick product" do
      perform!

      expect(fsc).to have_received(:signal)
        .with(symbol: contract_id, equity_usd: kind_of(Float))
    end

    # entry_z ~2 maps to confidence ~20 on the z*10 scale; the MTS-calibrated
    # RSE gate (30) would silently drop every 2 <= z < 3 entry — a different
    # strategy than the one that passed the gates.
    it "executes below the MTS-calibrated confidence gate when the entry says min_confidence 0" do
      perform!

      expect(positions_service).to have_received(:open_position)
        .with(hash_including(product_id: contract_id, side: :long, size: 1))
    end

    it "keeps the default confidence gate when the entry sets none" do
      stub_selection(contract_id => bip_entry.except("min_confidence"))

      perform!

      expect(positions_service).not_to have_received(:open_position)
    end
  end

  context "when the resolved contract has no enabled entry" do
    before do
      stub_selection({})
      allow(Strategy::MultiTimeframeSignal).to receive(:new).and_call_original
    end

    it "keeps today's MultiTimeframeSignal path untouched" do
      perform!

      expect(Strategy::MultiTimeframeSignal).to have_received(:new)
      expect(Strategy::FundingSkewContrarian).not_to have_received(:new)
    end
  end
end
