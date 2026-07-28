# frozen_string_literal: true

require "rails_helper"
require "tui"

RSpec.describe Tui::Forms::ClosePosition do
  let(:position) { create(:position, product_id: "NOL-19JUN26-CDE", status: "OPEN") }
  let(:executor) { instance_double(Trading::CoinbasePositions, close_position: {"success" => true}) }

  before do
    allow(Gum).to receive(:log)
    allow(Gum).to receive(:confirm).and_return(true)
    allow(Trading::CoinbasePositions).to receive(:new).and_return(executor)
  end

  it "closes the position through the executor" do
    described_class.run(position.id.to_s)

    expect(executor).to have_received(:close_position).with(
      hash_including(product_id: "NOL-19JUN26-CDE")
    )
  end

  it "does nothing when the operator declines the confirmation" do
    allow(Gum).to receive(:confirm).and_return(false)

    described_class.run(position.id.to_s)

    expect(executor).not_to have_received(:close_position)
  end

  # An operator close from the TUI is still an exit, so it must feed the
  # protections layer (ADR 0003) exactly as a bot-initiated exit does. Closing
  # through Trading::CoinbasePositions directly skipped the cooldown, the
  # stoploss guard, and the daily loss caps.
  it "records a cooldown so the protections layer sees the exit" do
    described_class.run(position.id.to_s)

    cooled = Trading::ProtectionLock.active.select { |l| l["symbol"] == "NOL-19JUN26-CDE" }
    expect(cooled).not_to be_empty
    expect(cooled.first["source"]).to eq("CooldownPeriod")
  end
end
