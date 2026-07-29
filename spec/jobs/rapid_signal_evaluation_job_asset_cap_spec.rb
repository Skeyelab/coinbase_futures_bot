# frozen_string_literal: true

require "rails_helper"

# The per-asset concurrent cap (config/asset_sizing.yml) never bound for futures
# because Position.by_asset matched on a product-id prefix that no contract code
# uses. Observed live: OIL is configured max_concurrent: 1 and three concurrent
# NOL shorts were open, stopped only by the GLOBAL cap of 3.
RSpec.describe RapidSignalEvaluationJob, "per-asset concurrent cap", type: :job do
  let(:contract_id) { "NOL-19AUG26-CDE" }
  let(:strategy) { instance_double(Strategy::MultiTimeframeSignal, last_rejection: nil) }
  let(:contract_manager) { instance_double(MarketData::FuturesContractManager) }
  let(:positions) { instance_double(Trading::CoinbasePositions) }
  let(:signal) { {side: "SHORT", quantity: 1, confidence: 90, price: 82.0, tp: 80.36, sl: 82.98} }

  before do
    allow(Strategy::MultiTimeframeSignal).to receive(:new).and_return(strategy)
    allow(MarketData::FuturesContractManager).to receive(:new).and_return(contract_manager)
    allow(Trading::CoinbasePositions).to receive(:new).and_return(positions)
    allow(contract_manager).to receive(:best_available_contract).and_return(contract_id)
    pass_cost_gate!(contract_id)
    allow(strategy).to receive(:signal).and_return(signal)
    allow(Trading::NotionalCap).to receive(:allows?).and_return(true)
    allow(Rails.application.config).to receive(:default_day_trading).and_return(true)
    Position.destroy_all
    SignalDecision.delete_all
    Contract.where(product_id: contract_id).delete_all
    create(:contract, product_id: contract_id, base_currency: "OIL")
  end

  def perform! = described_class.new.perform(product_id: contract_id, current_price: 82.0, asset: "OIL")

  it "opens the first OIL position" do
    expect(positions).to receive(:open_position).and_return({"success" => true})

    perform!
  end

  # OIL is configured max_concurrent: 1. This is the case that was live-broken.
  it "refuses a second OIL position while one is open" do
    create(:position, product_id: contract_id, status: "OPEN")

    expect(positions).not_to receive(:open_position)

    perform!
    expect(SignalDecision.last.reason).to eq("asset_position_cap")
  end

  it "records the cap it enforced" do
    create(:position, product_id: contract_id, status: "OPEN")
    allow(positions).to receive(:open_position)

    perform!

    expect(SignalDecision.last.context["cap"]).to eq(Trading::AssetSizing.for("OIL").max_concurrent)
  end

  # A closed position must not count against the live cap.
  it "allows an entry once the prior position is closed" do
    create(:position, product_id: contract_id, status: "CLOSED", close_time: 1.hour.ago)

    expect(positions).to receive(:open_position).and_return({"success" => true})

    perform!
  end
end
