# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trading::PositionTargetUpdater do
  let(:entry_price) { 100.0 }
  let(:position) { create(:position, side: "LONG", entry_price: entry_price) }

  describe ".call" do
    it "updates take_profit for a valid LONG target" do
      result = described_class.call(position: position, take_profit: 105.0)

      expect(result[:success]).to be(true)
      expect(position.reload.take_profit).to eq(105.0)
    end

    it "updates stop_loss for a valid LONG target" do
      result = described_class.call(position: position, stop_loss: 95.0)

      expect(result[:success]).to be(true)
      expect(position.reload.stop_loss).to eq(95.0)
    end

    it "updates both targets when valid for LONG" do
      result = described_class.call(position: position, take_profit: 110.0, stop_loss: 90.0)

      expect(result[:success]).to be(true)
      position.reload
      expect(position.take_profit).to eq(110.0)
      expect(position.stop_loss).to eq(90.0)
    end

    context "SHORT position" do
      let(:position) { create(:position, :short, entry_price: entry_price) }

      it "accepts take_profit below entry and stop_loss above entry" do
        result = described_class.call(position: position, take_profit: 95.0, stop_loss: 105.0)

        expect(result[:success]).to be(true)
      end

      it "rejects LONG-style take_profit above entry" do
        result = described_class.call(position: position, take_profit: 105.0)

        expect(result[:success]).to be(false)
        expect(result[:error]).to match(/take.profit/i)
      end
    end

    it "rejects non-open positions" do
      position.update!(status: "CLOSED", close_time: Time.current, pnl: 0)

      result = described_class.call(position: position, take_profit: 105.0)

      expect(result[:success]).to be(false)
      expect(result[:error]).to match(/OPEN/i)
    end

    it "rejects non-positive prices" do
      result = described_class.call(position: position, take_profit: 0)

      expect(result[:success]).to be(false)
      expect(result[:error]).to match(/positive/i)
    end

    it "rejects LONG take_profit at or below entry" do
      result = described_class.call(position: position, take_profit: 100.0)

      expect(result[:success]).to be(false)
      expect(result[:error]).to match(/take.profit/i)
    end

    it "rejects LONG stop_loss at or above entry" do
      result = described_class.call(position: position, stop_loss: 100.0)

      expect(result[:success]).to be(false)
      expect(result[:error]).to match(/stop.loss/i)
    end

    it "rejects when no targets are provided" do
      result = described_class.call(position: position)

      expect(result[:success]).to be(false)
      expect(result[:error]).to match(/No target/i)
    end
  end
end
