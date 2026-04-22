# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trading::TrailingStop::Runner do
  let(:logger) { instance_double(Logger, info: nil, error: nil, warn: nil) }
  let(:positions_service) { instance_double(Trading::CoinbasePositions) }
  let(:runner) { described_class.new(logger: logger, positions_service: positions_service) }

  let!(:position) do
    create(
      :position,
      side: "LONG",
      status: "OPEN",
      trailing_stop_enabled: true,
      trailing_stop_state: {
        "profit_percent" => 0.4,
        "t_stop_percent" => 0.2,
        "stop_percent" => 0.3
      }
    )
  end

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("TRAILING_STOP_ENABLED", "false").and_return("true")
    allow(ENV).to receive(:fetch).with("TRAILING_STOP_PRICE_SCALE", "5").and_return("5")
    allow(positions_service).to receive(:close_position).and_return({"success" => true})
  end

  describe "#evaluate_position" do
    it "persists trailing state and keeps holding when no stop trigger is hit" do
      create(:tick, product_id: position.product_id, price: position.entry_price * 1.01, observed_at: 1.minute.ago)

      signal = runner.evaluate_position(position)
      position.reload

      expect(signal).to eq(:hold)
      expect(position.trailing_stop_state["market_extreme"]).to be > 0
      expect(position.trailing_stop_state["last_signal"]).to eq("hold")
      expect(position.stop_loss).to be_present
    end
  end

  describe "#close_triggered_positions" do
    it "closes position when trailing stop triggers" do
      # First tick establishes market high.
      create(:tick, product_id: position.product_id, price: position.entry_price * 1.02, observed_at: 2.minutes.ago)
      runner.evaluate_position(position)

      # Second tick drops enough to cross the trailing stop.
      create(:tick, product_id: position.product_id, price: position.entry_price * 1.015, observed_at: 1.minute.ago)

      result = runner.close_triggered_positions(positions: Position.where(id: position.id))
      position.reload

      expect(result[:closed_count]).to eq(1)
      expect(result[:processed_ids]).to contain_exactly(position.id)
      expect(position.status).to eq("CLOSED")
      expect(positions_service).to have_received(:close_position).with(product_id: position.product_id, size: position.size)
    end

    it "skips work when disabled" do
      allow(ENV).to receive(:fetch).with("TRAILING_STOP_ENABLED", "false").and_return("false")
      result = runner.close_triggered_positions(positions: Position.where(id: position.id))

      expect(result).to eq({closed_count: 0, processed_ids: []})
      expect(positions_service).not_to have_received(:close_position)
    end
  end
end
