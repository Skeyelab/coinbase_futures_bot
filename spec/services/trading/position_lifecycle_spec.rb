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

      # Issue #397 (ADR 0003): a successful exit starts a CooldownPeriod so the
      # bot does not immediately re-enter the symbol it just left.
      it "starts a protection cooldown on the symbol" do
        lifecycle.close(position, reason: "Day trading closure")

        expect(Trading::Protections.blocked?(symbol: position.product_id, side: "long")).to be true
        expect(Trading::Protections.blocked?(symbol: position.product_id, side: "short")).to be true
      ensure
        Trading::ProtectionLock.clear!
      end

      # Issue #400: a cluster of losing closes trips the StoplossGuard, halting
      # the offending side and firing a Slack warning.
      context "StoplossGuard on a losing close" do
        around do |ex|
          orig = Rails.application.config.real_time_signals
          Rails.application.config.real_time_signals = orig.merge(
            protections: orig[:protections].merge(
              cooldown_seconds: 0, # isolate the guard from the always-on cooldown lock
              stoploss_guard: {threshold: 2, lookback_seconds: 3600, only_per_side: true, scope: "symbol", lock_ttl_seconds: 1800}
            )
          )
          ex.run
          Rails.application.config.real_time_signals = orig
          Trading::ProtectionLock.clear!
        end

        it "halts the losing side after the threshold and alerts Slack" do
          allow(SlackNotificationService).to receive(:alert)
          pid = position.product_id
          # A SHORT entered at 50k closing at 51k is a genuine loss (DB pnl < 0).
          position.update!(side: "SHORT")
          # one prior losing SHORT close within the window -> this makes 2
          create(:position, product_id: pid, side: "SHORT", status: "CLOSED",
            close_time: 10.minutes.ago, pnl: -25.0)

          expect(SlackNotificationService).to receive(:alert).with("warning", /StoplossGuard/i, anything)
          lifecycle.close(position, reason: "stop_loss")

          expect(Trading::Protections.blocked?(symbol: pid, side: "short")).to be true
          expect(Trading::Protections.blocked?(symbol: pid, side: "long")).to be false
        end

        it "does not halt on a winning close" do
          allow(SlackNotificationService).to receive(:alert)
          # position stays LONG: entry 50k closing at 51k is a WIN (DB pnl > 0).
          create(:position, product_id: position.product_id, side: "LONG", status: "CLOSED",
            close_time: 10.minutes.ago, pnl: -25.0)

          expect(SlackNotificationService).not_to receive(:alert)
          lifecycle.close(position, reason: "take_profit")
          expect(Trading::Protections.blocked?(symbol: position.product_id, side: "long")).to be false
        end
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

      # No exit happened (position stays OPEN), so no cooldown should start.
      it "does not start a protection cooldown on a failed close" do
        lifecycle.close(position, reason: "Day trading closure")

        expect(Trading::Protections.blocked?(symbol: position.product_id, side: "long")).to be false
      ensure
        Trading::ProtectionLock.clear!
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
