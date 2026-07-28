# frozen_string_literal: true

require "rails_helper"

# The overnight-margin gate computed a per-position requirement and threw it away.
#
# `position_exceeds_margin_requirements?` called
# `calculate_position_margin_requirement` and discarded the result, then compared
# account-wide `available_margin` against a buffer that is independent of the
# position being evaluated. Every swing position therefore passed or failed
# together — the number the method had just computed had no bearing on the
# decision, and the emergency closure that consumes those violations picked the
# smallest CONTRACT COUNT out of a set that was really "all of them".
#
# Two positions with different contract sizes are what expose it. A single
# position, or two of the same contract size, passes either way — which is
# exactly how this survived.
RSpec.describe MarginWindowMonitoringJob, type: :job do
  let(:logger) { Rails.logger }
  let(:positions_service) { instance_double(Trading::CoinbasePositions, authenticated?: true) }
  let(:advanced_trade_client) { instance_double(Coinbase::AdvancedTradeClient) }
  let(:swing_manager) do
    instance_double(Trading::SwingPositionManager, check_swing_risk_limits: {risk_status: "acceptable", violations: []})
  end

  let(:overnight_window) { {"margin_window" => {"margin_window_type" => "OVERNIGHT_MARGIN"}} }

  # NOL: contract_size 10. 5 contracts x $80 x 10 = $4,000 notional,
  # 20% overnight = $800 required.
  let!(:nol) do
    create(:position, :swing_trading, product_id: "NOL-19AUG26-CDE", size: 5, entry_price: 80.0)
  end

  # BIP: contract_size 0.01. 1 contract x $100,000 x 0.01 = $1,000 notional,
  # 20% overnight = $200 required. Deliberately the SMALLER requirement but the
  # SMALLER contract count too, so a size-ordered closure of an
  # everything-is-flagged set picks this one.
  let!(:bip) do
    create(:position, :swing_trading, product_id: "BIP-20DEC30-CDE", size: 1, entry_price: 100_000.0)
  end

  # $10,000 equity, 20% buffer => the account cushion is breached below $2,000.
  let(:available_margin) { 600.0 }
  let(:balance_summary) do
    {
      "futures_buying_power" => "8000.0",
      "total_usd_balance" => "10000.0",
      "available_margin" => available_margin.to_s,
      "initial_margin" => "2000.0",
      "liquidation_threshold" => "500.0"
    }
  end

  before do
    allow(Trading::CoinbasePositions).to receive(:new).and_return(positions_service)
    allow(Coinbase::AdvancedTradeClient).to receive(:new).and_return(advanced_trade_client)
    allow(Trading::SwingPositionManager).to receive(:new).and_return(swing_manager)
    allow(advanced_trade_client).to receive(:get_current_margin_window).and_return(overnight_window)
    allow(advanced_trade_client).to receive(:get_futures_balance_summary).and_return(balance_summary)
    allow(Trading::ContractSizeResolver).to receive(:for_product).with("NOL-19AUG26-CDE").and_return(10.0)
    allow(Trading::ContractSizeResolver).to receive(:for_product).with("BIP-20DEC30-CDE").and_return(0.01)
    allow(SentryHelper).to receive(:add_breadcrumb)
    allow(SlackNotificationService).to receive(:alert)
    allow(PositionCloseJob).to receive(:perform_now)

    sentry_scope = double("sentry_scope").as_null_object
    allow(Sentry).to receive(:with_scope).and_yield(sentry_scope)
    allow(Sentry).to receive(:capture_message)
  end

  describe "which swing positions the gate flags" do
    # Cushion breached ($600 < $2,000) but above the 5% emergency floor ($500),
    # so this exercises flagging without closure.
    it "flags only the position whose own margin requirement is not covered" do
      described_class.perform_now

      expect(SlackNotificationService).to have_received(:alert).with(
        "critical",
        "Swing Position Margin Violations",
        "1 swing positions exceed margin requirements: NOL-19AUG26-CDE (5.0 contracts)"
      )
    end

    context "when the account margin cushion is intact" do
      let(:available_margin) { 5000.0 }

      # The account-level buffer stays a precondition: a healthy cushion means
      # no swing position needs flattening, whatever its individual requirement.
      it "flags nothing" do
        described_class.perform_now

        expect(SlackNotificationService).not_to have_received(:alert)
          .with("critical", "Swing Position Margin Violations", anything)
      end
    end
  end

  describe "which position the margin emergency closes" do
    # $300 is below the 5% emergency floor, so closure fires.
    # NOL needs $800 (> $300, breaches); BIP needs $200 (<= $300, covered).
    let(:available_margin) { 300.0 }

    it "closes the breaching position, not the one with the fewest contracts" do
      described_class.perform_now

      expect(PositionCloseJob).to have_received(:perform_now).with(
        position_id: nol.id,
        reason: "emergency_margin_violation",
        priority: "critical"
      )
    end

    it "leaves the position whose requirement is covered alone" do
      described_class.perform_now

      expect(PositionCloseJob).not_to have_received(:perform_now)
        .with(hash_including(position_id: bip.id))
    end
  end
end
