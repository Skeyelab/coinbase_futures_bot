# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trading::PositionLifecycle do
  subject(:lifecycle) { described_class.new(positions_service: positions_service, logger: logger) }

  let(:positions_service) { instance_double(Trading::CoinbasePositions) }
  let(:logger) { instance_double(ActiveSupport::Logger, info: nil, warn: nil, error: nil) }
  let(:position) { create(:position, status: "OPEN", entry_price: 50_000.0) }

  before do
    allow(RecentMarketPrice).to receive(:for_product).with(position.product_id).and_return(51_000.0)
  end

  describe "#close" do
    context "API success" do
      before do
        allow(positions_service).to receive(:close_position).and_return({"success" => true, "order_id" => "abc123"})
      end

      it "returns successful result" do
        result = lifecycle.close(position, reason: "Day trading closure")
        expect(result).to be_success
      end

      it "closes position locally" do
        lifecycle.close(position, reason: "Day trading closure")
        expect(position.reload.status).to eq("CLOSED")
      end

      it "sets close price on result" do
        result = lifecycle.close(position, reason: "Day trading closure")
        expect(result.close_price).to eq(51_000.0)
      end

      it "result not fallback" do
        result = lifecycle.close(position, reason: "Day trading closure")
        expect(result.fallback).to be false
      end
    end

    # A failed exchange close must NOT be reported as success and must NOT mark
    # the DB position CLOSED. Doing so creates a "phantom-flat" position: the bot
    # believes it is out while real exposure remains on the exchange. Fail loud so
    # callers retry/alert instead of trading blind. See fail-loud-close.
    context "API bad response" do
      before do
        allow(positions_service).to receive(:close_position).and_return({"error" => "insufficient funds"})
      end

      it "reports failure (does not fake success)" do
        result = lifecycle.close(position, reason: "Day trading closure")
        expect(result).not_to be_success
      end

      it "leaves the position OPEN so exposure is not hidden" do
        lifecycle.close(position, reason: "Day trading closure")
        expect(position.reload.status).to eq("OPEN")
      end

      it "logs an error" do
        expect(logger).to receive(:error).with(/close failed/i)
        lifecycle.close(position, reason: "Day trading closure")
      end
    end

    context "API raises exception" do
      before do
        allow(positions_service).to receive(:close_position).and_raise(StandardError, "network timeout")
      end

      it "reports failure (does not fake success)" do
        result = lifecycle.close(position, reason: "Day trading closure")
        expect(result).not_to be_success
      end

      it "leaves the position OPEN so exposure is not hidden" do
        lifecycle.close(position, reason: "Day trading closure")
        expect(position.reload.status).to eq("OPEN")
      end
    end

    context "no price from any source" do
      before do
        allow(RecentMarketPrice).to receive(:for_product).with(position.product_id).and_return(nil)
        allow(position).to receive(:entry_price).and_return(nil)
        allow(positions_service).to receive(:close_position).and_return({"success" => true})
      end

      it "returns failure result" do
        result = lifecycle.close(position, reason: "Day trading closure")
        expect(result).not_to be_success
      end

      it "does not close position" do
        lifecycle.close(position, reason: "Day trading closure")
        expect(position.reload.status).to eq("OPEN")
      end
    end
  end
end
