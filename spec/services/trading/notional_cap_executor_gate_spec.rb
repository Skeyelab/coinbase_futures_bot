# frozen_string_literal: true

require "rails_helper"

# Issue #530. NotionalCap.allows? had exactly one call site — the decision
# layer (RapidSignalEvaluationJob) — so every path that reached
# Trading::CoinbasePositions without going through RSE added notional with no
# ceiling: the web UI open/increase, FuturesExecutor, and the calibration
# runner. An operator adding contracts one increase at a time could walk
# straight past ACCOUNT_NOTIONAL_MULTIPLE.
#
# The cap is now enforced at the submit_order chokepoint — the same single
# boundary that carries the dry-run and paper-default guarantees — so all
# entry paths inherit it. Exits are NEVER gated: blocking a close at the cap
# would trap exactly the oversized exposure the cap exists to prevent.
RSpec.describe Trading::CoinbasePositions, "notional cap at the executor (#530)", notional_cap: true do
  let(:service) { described_class.new }
  let(:product) { "BIT-29AUG25-CDE" }

  before do
    allow(DryRun).to receive(:active?).and_return(true)
    allow(service).to receive(:get_current_market_price).and_return(100.0)
    allow(Trading::ContractSizeResolver).to receive(:for_product).and_return(1)
  end

  context "when the account is at its notional ceiling" do
    before { allow(Trading::NotionalCap).to receive(:allows?).and_return(false) }

    it "refuses to open a position" do
      result = service.open_position(product_id: product, side: :buy, size: 1)

      expect(result["success"]).to be false
      expect(result["error"]).to match(/notional cap/i)
      expect(Position.count).to eq(0)
    end

    it "refuses to increase a position" do
      position = create(:position, product_id: product, side: "LONG", size: 1,
        status: "OPEN", paper: true)
      allow(service).to receive(:list_open_positions).and_return([
        {"product_id" => product, "number_of_contracts" => "1", "side" => "LONG"}
      ])

      result = service.increase_position(product_id: product, size: 1, position: position)

      expect(result["success"]).to be false
      expect(position.reload.size.to_f).to eq(1.0)
    end

    it "still allows a close — an exit reduces the exposure the cap bounds" do
      create(:position, product_id: product, side: "LONG", size: 1,
        status: "OPEN", paper: true)

      result = service.close_position(product_id: product, size: "1")

      expect(result["success"]).to be true
    end
  end

  context "when the cap has room (or fails open on unreadable equity)" do
    before { allow(Trading::NotionalCap).to receive(:allows?).and_return(true) }

    it "opens normally" do
      result = service.open_position(product_id: product, side: :buy, size: 1)

      expect(result["success"]).to be true
    end
  end

  it "consults the cap with the product, size and price of the order" do
    allow(Trading::NotionalCap).to receive(:allows?).and_return(true)

    service.open_position(product_id: product, side: :buy, size: 2)

    expect(Trading::NotionalCap).to have_received(:allows?)
      .with(product_id: product, quantity: 2, price: 100.0)
  end
end
