# frozen_string_literal: true

require "rails_helper"

# Issue #537. On 2026-07-28 a RISK halt was in force for 14 minutes. Paper
# position 14's take-profit fired twice, all four close attempts (2 + 2 retries)
# raised TradingHalt::HaltedError, and the position was still open afterwards
# with its take-profit unfilled.
#
# The kill switch is for stopping NEW risk. Preventing risk REDUCTION is the
# opposite of safety: it holds a position through its own stop-loss, and a RISK
# halt needs a console to clear (#481) so the window is long.
RSpec.describe "a trading halt must not block exits (issue #537)" do
  let(:product_id) { "NOL-19AUG26-CDE" }

  before do
    allow(DryRun).to receive(:active?).and_return(true)
    TradingHalt.halt!(reason: "calibration abort (simulating #535)")
  end

  after { TradingHalt.resume!(acknowledge_risk: true, operator: "spec") }

  it "is actually halted, so the rest of this spec means something" do
    expect(TradingHalt.halted?).to be(true)
  end

  describe "the exit path" do
    subject(:service) { Trading::CoinbasePositions.new }

    it "closes a position while halted" do
      allow(service).to receive(:infer_position).and_return([1.0, "SHORT"])
      allow(service).to receive(:place_order_for_close).and_return({"order_id" => "X"}) if service.respond_to?(:place_order_for_close, true)

      expect { service.close_position(product_id: product_id, size: 1.0) }
        .not_to raise_error
    end
  end

  describe "the entry paths, which a halt SHOULD stop" do
    subject(:service) { Trading::CoinbasePositions.new }

    it "still refuses to open a position while halted" do
      expect { service.open_position(product_id: product_id, side: "BUY", size: 1) }
        .to raise_error(TradingHalt::HaltedError)
    end

    it "still refuses to increase a position while halted" do
      expect { service.increase_position(product_id: product_id, size: 1) }
        .to raise_error(TradingHalt::HaltedError)
    end
  end

  # The halt and ADR 0006 suspension are the two ways to stop trading. They must
  # agree that exits proceed — suspension already documents "new entries only".
  it "agrees with symbol suspension on exit semantics" do
    Trading::SymbolSuspension.suspend!(product_id, reason: "spec")
    expect(Trading::SymbolSuspension.suspended?(product_id)).to be(true)

    service = Trading::CoinbasePositions.new
    allow(service).to receive(:infer_position).and_return([1.0, "SHORT"])

    expect { service.close_position(product_id: product_id, size: 1.0) }
      .not_to raise_error
  ensure
    Trading::SymbolSuspension.enable!(product_id, reason: "spec cleanup")
  end
end
