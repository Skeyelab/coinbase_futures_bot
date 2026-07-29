# frozen_string_literal: true

require "rails_helper"

# Issue #484 (the paper half of #390). BIP carries a 2030 dummy expiry, so
# current_month_for_asset("BTC") skips it and returns the DATED BIT contract.
# A BIP tick was therefore evaluated on the perp's price feed and executed on
# the dated future — wrong instrument, mismatched feed, and no amount of BIP
# data would ever accumulate as BIP trades.
RSpec.describe RapidSignalEvaluationJob, "contract routing", type: :job do
  let(:strategy) { instance_double(Strategy::MultiTimeframeSignal) }
  let(:contract_manager) { instance_double(MarketData::FuturesContractManager) }
  let(:positions) { instance_double(Trading::CoinbasePositions) }
  let(:signal) { {side: "LONG", quantity: 1, confidence: 90, price: 64_700.0, tp: 65_000.0, sl: 64_200.0} }

  before do
    allow(Strategy::MultiTimeframeSignal).to receive(:new).and_return(strategy)
    allow(MarketData::FuturesContractManager).to receive(:new).and_return(contract_manager)
    allow(Trading::CoinbasePositions).to receive(:new).and_return(positions)
    allow(strategy).to receive(:signal).and_return(signal)
    allow(Rails.application.config).to receive(:default_day_trading).and_return(true)
    allow(positions).to receive(:open_position).and_return({"success" => true})
    Position.destroy_all
    # Exposure is #437's concern with its own specs; routing is not about it.
    allow(Trading::NotionalCap).to receive(:allows?).and_return(true)
  end

  def perform!(product_id:)
    described_class.new.perform(product_id: product_id, current_price: 64_700.0, asset: "BTC")
  end

  it "trades the perp itself when the tick names the perp" do
    create(:contract, product_id: "BIP-20DEC30-CDE", base_currency: "BTC", enabled: true,
      expiration_date: Date.new(2030, 12, 20))

    # Stubbed to the DATED contract on purpose: if routing still re-resolved by
    # asset, the perp tick would execute on BIT and this would catch it.
    allow(contract_manager).to receive(:best_available_contract).with("BTC").and_return("BIT-29AUG26-CDE")
    pass_cost_gate!("BIP-20DEC30-CDE")

    perform!(product_id: "BIP-20DEC30-CDE")

    expect(positions).to have_received(:open_position)
      .with(hash_including(product_id: "BIP-20DEC30-CDE"))
    expect(contract_manager).not_to have_received(:best_available_contract)
  end

  it "trades the dated contract the tick names, rather than re-resolving it" do
    create(:contract, product_id: "BIT-29AUG26-CDE", base_currency: "BTC", enabled: true,
      expiration_date: 1.month.from_now.to_date)
    pass_cost_gate!("BIT-29AUG26-CDE")

    perform!(product_id: "BIT-29AUG26-CDE")

    expect(positions).to have_received(:open_position)
      .with(hash_including(product_id: "BIT-29AUG26-CDE"))
  end

  # A spot tick names no contract, so it still resolves by asset — this is what
  # keeps dated rollover working.
  it "resolves by asset for a spot tick" do
    allow(contract_manager).to receive(:best_available_contract).with("BTC").and_return("BIT-29AUG26-CDE")
    pass_cost_gate!("BIT-29AUG26-CDE")

    perform!(product_id: "BTC-USD")

    expect(positions).to have_received(:open_position)
      .with(hash_including(product_id: "BIT-29AUG26-CDE"))
  end

  # Issue #390 (the other half): a BTC tick that names no contract must resolve
  # to the BIP perp, because ADR 0002 made BIP the home instrument and ADR 0004
  # condition 1 left no discretion. Real contract manager, real Contract rows:
  # the whole point is the resolution rule, so stubbing it would test nothing.
  context "with real contract resolution" do
    before do
      allow(MarketData::FuturesContractManager).to receive(:new).and_call_original
      create(:contract, product_id: "BIT-28AUG26-CDE", base_currency: "BTC", enabled: true,
        expiration_date: 1.month.from_now.to_date)
    end

    it "routes a spot BTC tick to the BIP perp rather than the dated BIT contract" do
      create(:contract, product_id: "BIP-20DEC30-CDE", base_currency: "BTC", enabled: true,
        expiration_date: Date.new(2030, 12, 20))
      pass_cost_gate!("BIP-20DEC30-CDE")

      perform!(product_id: "BTC-USD")

      expect(positions).to have_received(:open_position)
        .with(hash_including(product_id: "BIP-20DEC30-CDE"))
    end

    it "opens no position at all when BTC has no tradeable perp" do
      perform!(product_id: "BTC-USD")

      expect(positions).not_to have_received(:open_position)
    end

    # A suspended perp must not become a reason to trade the dated contract —
    # that would route around the operator's decision instead of obeying it. The
    # tick still resolves to BIP; the entry gate is what refuses, on the symbol
    # that was actually suspended.
    it "refuses the entry on the suspended perp instead of falling back to BIT" do
      create(:contract, product_id: "BIP-20DEC30-CDE", base_currency: "BTC", enabled: true,
        expiration_date: Date.new(2030, 12, 20))
      Trading::SymbolSuspension.suspend!("BIP-20DEC30-CDE", reason: "awaiting walk-forward")

      perform!(product_id: "BTC-USD")

      expect(positions).not_to have_received(:open_position)
    end
  end

  # An expiring contract must roll rather than be traded into expiry.
  it "falls back to month resolution when the named contract is no longer tradeable" do
    create(:contract, product_id: "BIT-28JUL26-CDE", base_currency: "BTC", enabled: true,
      expiration_date: Date.current)
    allow(contract_manager).to receive(:best_available_contract).with("BTC").and_return("BIT-29AUG26-CDE")
    pass_cost_gate!("BIT-29AUG26-CDE")

    perform!(product_id: "BIT-28JUL26-CDE")

    expect(positions).to have_received(:open_position)
      .with(hash_including(product_id: "BIT-29AUG26-CDE"))
  end
end
