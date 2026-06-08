# frozen_string_literal: true

require "rails_helper"
require "tui"

RSpec.describe Tui::Forms::EditPositionTarget do
  let(:position) { create(:position, entry_price: 100.0, take_profit: 110.0, stop_loss: 90.0) }

  before do
    allow(Gum).to receive(:log)
    allow(Gum).to receive(:input).and_return("105")
    allow(Gum).to receive(:confirm).and_return(true)
    allow(Trading::PositionTargetUpdater).to receive(:call).and_return({success: true, position: position})
  end

  it "updates take-profit through the updater service" do
    described_class.run(field: :take_profit, id_str: position.id.to_s)

    expect(Trading::PositionTargetUpdater).to have_received(:call).with(
      position: position,
      take_profit: 105.0
    )
  end

  it "converts dollar take-profit input to price before updating" do
    allow(Trading::ContractSizeResolver).to receive(:for_product).and_return(1)
    position.update!(entry_price: 100.0, product_id: "BIT-26JUN26-CDE")
    allow(Gum).to receive(:input).and_return("$10")

    described_class.run(field: :take_profit, id_str: position.id.to_s)

    expect(Trading::PositionTargetUpdater).to have_received(:call).with(
      position: position,
      take_profit: 110.0
    )
  end

  it "warns when editing stop-loss with trailing stop enabled" do
    position.update!(trailing_stop_enabled: true)

    described_class.run(field: :stop_loss, id_str: position.id.to_s)

    expect(Gum).to have_received(:log).with(/Trailing stop enabled/, level: "warn")
  end

  it "rejects invalid position ids" do
    described_class.run(field: :take_profit, id_str: "abc")

    expect(Trading::PositionTargetUpdater).not_to have_received(:call)
    expect(Gum).to have_received(:log).with(/Invalid position id/, level: "error")
  end
end
