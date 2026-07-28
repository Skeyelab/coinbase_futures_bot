# frozen_string_literal: true

require "rails_helper"

# Issue #482. When CoinbasePositions realizes a close itself (no caller owns
# the row — an operator-initiated or API-detected close), the exit never
# passes through PositionLifecycle, which is where the loss caps are normally
# evaluated. These pin that this path evaluates them too: a loss must trip the
# halt on the trade that breached it, not on the next lifecycle close.
RSpec.describe Trading::CoinbasePositions, "loss caps on self-realized closes (#482)" do
  let(:service) { described_class.new }

  before { allow(Trading::LossLimits).to receive(:evaluate!) }

  def realize_close(position, size: nil)
    service.send(:update_local_position_record,
      product_id: position.product_id,
      size: size,
      close_price: 100.0,
      order_result: {"order_id" => "test-order"})
  end

  it "evaluates the caps after realizing a full close" do
    position = create(:position, product_id: "BIT-29AUG25-CDE", side: "LONG",
      entry_price: 110.0, size: 1, status: "OPEN")

    realize_close(position)

    expect(position.reload.status).to eq("CLOSED")
    expect(Trading::LossLimits).to have_received(:evaluate!)
  end

  it "evaluates the caps after realizing a partial close" do
    position = create(:position, product_id: "BIT-29AUG25-CDE", side: "LONG",
      entry_price: 110.0, size: 3, status: "OPEN")

    portion = realize_close(position, size: 1)

    expect(portion).to be_present
    expect(portion.status).to eq("CLOSED")
    expect(position.reload.status).to eq("OPEN")
    expect(Trading::LossLimits).to have_received(:evaluate!)
  end

  it "does not evaluate when the caller owns realizing the row" do
    position = create(:position, product_id: "BIT-29AUG25-CDE", side: "LONG",
      entry_price: 110.0, size: 1, status: "OPEN")

    service.send(:update_local_position_record,
      product_id: position.product_id,
      size: nil,
      close_price: 100.0,
      order_result: {"order_id" => "test-order"},
      position: position)

    expect(position.reload.status).to eq("OPEN")
    expect(Trading::LossLimits).not_to have_received(:evaluate!)
  end

  it "still returns the realized close when evaluation raises" do
    allow(Trading::LossLimits).to receive(:evaluate!).and_raise(StandardError, "db hiccup")
    position = create(:position, product_id: "BIT-29AUG25-CDE", side: "LONG",
      entry_price: 110.0, size: 1, status: "OPEN")

    result = realize_close(position)

    expect(result).to eq(position)
    expect(position.reload.status).to eq("CLOSED")
  end
end
