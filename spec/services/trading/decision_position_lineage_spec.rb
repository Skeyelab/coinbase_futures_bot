# frozen_string_literal: true

require "rails_helper"

# #480/#488 shipped the decision ledger with a position_id column, a recorder
# that accepts it, and a caller that passes it — and it was nil on every traded
# decision. Observed on exo-mini: 12 traded decisions, 0 with a position link.
#
# These exercise the lineage through the PUBLIC interface only. An earlier draft
# also poked create_local_position_record directly and asserted it "returns the
# Position, not the logger's return value" — that named the implementation, and
# would break on a rename while the behaviour was fine. The examples below catch
# the same regression (verified: both fail without the fix) and survive a
# refactor of how the position gets created.
RSpec.describe Trading::CoinbasePositions, "decision → position lineage (#480)" do
  subject(:service) { described_class.new }

  let(:product_id) { "BIP-20DEC30-CDE" }

  before do
    allow(DryRun).to receive(:active?).and_return(true)
    allow(service).to receive(:get_current_market_price).and_return(63_700.0)
  end

  it "surfaces the position it created, so a caller can link the order to it" do
    result = service.open_position(product_id: product_id, side: "BUY", size: 1)

    expect(result["position_id"]).to be_present
    expect(Position.find(result["position_id"]).product_id).to eq(product_id)
  end

  it "carries the position through to the recorded decision" do
    opened = service.open_position(product_id: product_id, side: "BUY", size: 1)
    recorder = Trading::DecisionRecorder.new(product_id: product_id, asset: "BTC")

    recorder.traded(signal: {side: "BUY", confidence: 42.0, quantity: 1},
      position_id: opened["position_id"])

    decision = SignalDecision.order(:id).last
    expect(decision.disposition).to eq(SignalDecision::TRADED)
    # The join gate 2a ultimately needs: a decision, and what it actually did.
    expect(Position.find(decision.position_id).product_id).to eq(product_id)
  end

  it "opens without a position link rather than raising when the row cannot be written" do
    allow(Position).to receive(:create!).and_raise(StandardError, "boom")
    allow(Rails.logger).to receive(:error)

    result = nil
    expect { result = service.open_position(product_id: product_id, side: "BUY", size: 1) }
      .not_to raise_error
    expect(result["position_id"]).to be_nil
  end
end
