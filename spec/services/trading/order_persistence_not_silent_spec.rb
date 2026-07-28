# frozen_string_literal: true

require "rails_helper"

# A failure to record an Order was silent, and it cost six days of order history.
#
# Every simulated order carried the id "DRY-RUN-1" (fixed in #540). The first one
# persisted on 2026-07-22; every later Order.create! failed the coinbase_order_id
# uniqueness validation. #persist_order rescued it, logged, and returned — so the
# Position was committed, the Order was absent, and open_position reported plain
# success. Live result: 17 positions, 1 Order. ADR 0001 made Orders first-class
# for slippage audit and outage reconciliation; both were unavailable for six days
# and nothing surfaced it.
#
# The collision below is REAL, not a stub of Order.create!: the only thing faked
# is the randomness the dry-run id is drawn from, so the id genuinely collides
# with a row already in the table and ActiveRecord genuinely refuses it.
RSpec.describe Trading::CoinbasePositions, "order persistence is never silent" do
  subject(:service) { described_class.new(logger: Logger.new(IO::NULL)) }

  let(:product_id) { "BIP-20DEC30-CDE" }

  before do
    allow(DryRun).to receive(:active?).and_return(true)
    allow(service).to receive(:get_current_market_price).and_return(63_700.0)
    allow(SlackNotificationService).to receive(:alert)
  end

  context "when the entry Order cannot be written" do
    before do
      allow(SecureRandom).to receive(:hex).and_call_original
      allow(SecureRandom).to receive(:hex).with(8).and_return("c0ffeec0ffeec0ff")

      Order.create!(contract_id: "BIT-31JUL26-CDE", side: "buy", order_type: "market",
        quantity: 1, status: "filled", coinbase_order_id: "DRY-RUN-c0ffeec0ffeec0ff")
    end

    it "tells the caller the order record is missing instead of reporting plain success" do
      result = service.open_position(product_id: product_id, side: "BUY", size: 1)

      expect(result["order_record_missing"]).to be(true)
    end

    it "alerts an operator rather than only writing a log line nobody reads" do
      service.open_position(product_id: product_id, side: "BUY", size: 1)

      expect(SlackNotificationService).to have_received(:alert)
        .with("critical", a_string_matching(/order/i), anything)
    end

    # The exchange order is ALREADY PLACED by the time we write locally. Rolling
    # the Position back would leave real exposure with no local record at all,
    # which is strictly worse than a missing audit row — the same reasoning
    # PositionLifecycle uses to refuse a "phantom-flat" position. So: keep the
    # Position, and make the gap loud.
    it "still keeps the local Position, because the venue order cannot be rolled back" do
      result = service.open_position(product_id: product_id, side: "BUY", size: 1)

      expect(result["position_id"]).to be_present
      expect(Position.find(result["position_id"]).status).to eq("OPEN")
    end
  end

  context "when the entry Order is written" do
    it "reports no gap" do
      result = service.open_position(product_id: product_id, side: "BUY", size: 1)

      expect(result["order_record_missing"]).to be_nil
      expect(Position.find(result["position_id"]).orders.count).to eq(1)
    end

    # Observed live on exo-mini 2026-07-28, hidden by the same silence:
    # "Failed to persist Order record: Validation failed: Side is not included in
    # the list", immediately followed by "Successfully opened short position".
    # SideNormalizer.order("short") is "SHORT"; Order#side only admits buy/sell.
    it "records the entry Order for a short entry too" do
      result = service.open_position(product_id: product_id, side: "short", size: 1)

      expect(result["order_record_missing"]).to be_nil
      expect(Position.find(result["position_id"]).orders.pluck(:side)).to eq(["sell"])
    end
  end
end
