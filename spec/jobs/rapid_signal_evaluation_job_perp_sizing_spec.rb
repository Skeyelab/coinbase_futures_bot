# frozen_string_literal: true

require "rails_helper"

# Sizing resolved by base currency alone could not tell BIP (BTC perp, ~$659 a
# contract) from BIT (dated BTC nano, ~$100 a contract): both map to "BTC" in
# Contract::PREFIX_TO_BASE_CURRENCY, so the perp inherited the nano's
# 5-contract / 2-concurrent shape. Issue #486 precondition 4 pins BIP to 1/1.
RSpec.describe RapidSignalEvaluationJob, "perp sizing is resolved per contract", type: :job do
  let(:perp_id) { "BIP-20DEC30-CDE" }
  let(:strategy) { instance_double(Strategy::MultiTimeframeSignal, last_rejection: nil) }
  let(:contract_manager) { instance_double(MarketData::FuturesContractManager) }
  let(:positions) { instance_double(Trading::CoinbasePositions) }
  let(:signal) { {side: "LONG", quantity: 1, confidence: 90, price: 65_900.0, tp: 66_163.6, sl: 65_702.3} }

  before do
    allow(Strategy::MultiTimeframeSignal).to receive(:new).and_return(strategy)
    allow(MarketData::FuturesContractManager).to receive(:new).and_return(contract_manager)
    allow(Trading::CoinbasePositions).to receive(:new).and_return(positions)
    allow(contract_manager).to receive(:current_month_contract).and_return(perp_id)
    allow(strategy).to receive(:signal).and_return(signal)
    allow(Trading::NotionalCap).to receive(:allows?).and_return(true)
    allow(Rails.application.config).to receive(:default_day_trading).and_return(true)
    Position.destroy_all
    SignalDecision.delete_all
    Contract.where(product_id: perp_id).delete_all
    create(:contract, product_id: perp_id, base_currency: "BTC")
  end

  def perform! = described_class.new.perform(product_id: perp_id, current_price: 65_900.0, asset: "BTC")

  # The bug: BTC's max_concurrent is 2, so a second BIP position was permitted.
  it "refuses a second BIP position while one is open" do
    create(:position, product_id: perp_id, status: "OPEN")

    expect(positions).not_to receive(:open_position)

    perform!
    expect(SignalDecision.last.reason).to eq("asset_position_cap")
  end

  it "enforces BIP's own concurrent cap of 1, not the dated BTC nano's 2" do
    create(:position, product_id: perp_id, status: "OPEN")
    allow(positions).to receive(:open_position)

    perform!

    expect(SignalDecision.last.context["cap"]).to eq(1)
  end

  # The other half of the same bug: the fallback notional. BTC's entry says
  # $100/contract (the dated nano), which understates a BIP contract 6.6x, so a
  # resolver failure would size six times too large.
  it "sizes the strategy off BIP's own contract notional when the resolver fails" do
    allow(Trading::ContractSizeResolver).to receive(:for_product)
      .and_return(Trading::ContractSizeResolver::DEFAULT_CONTRACT_SIZE)
    allow(positions).to receive(:open_position).and_return({"success" => true})

    expect(Strategy::MultiTimeframeSignal).to receive(:new)
      .with(hash_including(contract_size_usd: 659.0, max_position_size: 1))
      .and_return(strategy)

    perform!
  end
end
