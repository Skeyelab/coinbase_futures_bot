# frozen_string_literal: true

require "rails_helper"

# Every simulated order used to be issued the id "DRY-RUN-1".
#
# #simulate_order built a fresh PaperTrading::ExchangeSimulator per call, and
# the simulator's id sequence is per-instance state starting at 0 — so
# `@id_seq += 1` returned 1 every time. The instance was then discarded, along
# with its orders hash and its equity tracking, which means the whole call
# existed to return the number 1.
#
# ADR 0001 made Orders first-class specifically so the exchange order id would
# support outage reconciliation: "on restart, the bot can query Coinbase for
# pending order status and reconcile against stored records". One id shared by
# every order defeats that, and defeats duplicate detection with it — the #486
# calibration run aborted on exactly that, refusing to trust a fill count it
# could not de-duplicate.
RSpec.describe Trading::CoinbasePositions, type: :service do
  subject(:service) { described_class.new(logger: Logger.new(IO::NULL)) }

  describe "#simulate_order order ids" do
    def place
      service.send(:simulate_order,
        product_id: "NOL-19AUG26-CDE", side: :sell, size: 1, price: 80.0)["order_id"]
    end

    it "issues a distinct id to every simulated order" do
      ids = Array.new(5) { place }

      expect(ids.uniq.size).to eq(5)
    end

    it "still marks the id as dry-run so it is never mistaken for a venue id" do
      expect(place).to start_with("DRY-RUN-")
    end

    it "issues ids that survive being persisted as distinct Orders" do
      a = place
      b = place

      expect(a).not_to eq(b)
    end
  end
end
