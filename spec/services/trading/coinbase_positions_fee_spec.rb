# frozen_string_literal: true

require "rails_helper"

# Simulated-fill fees must be priced per venue (issue #458 / ADR 0004).
#
# #simulate_order inlined CostModel.taker_fee_rate and .min_fee_per_contract —
# the PERP schedule — for every product. So a dated NOL fill recorded a 3 bps /
# $0.15 perp cost instead of 9 bps / $0.85, understating the cost of the only
# instrument this bot has ever actually traded. CostModel.fee_for already
# resolves per venue and prefers a real measured commission over a constant.
RSpec.describe Trading::CoinbasePositions, type: :service do
  subject(:service) { described_class.new(logger: Logger.new(IO::NULL)) }

  describe "#simulate_order fee" do
    # No FundingRate rows -> CostModel.perp?(symbol) is false -> dated schedule.
    it "prices a dated contract on the dated schedule, not the perp one" do
      fee = service.send(:simulate_order,
        product_id: "NOL-19AUG26-CDE", side: :sell, size: 2, price: 80.0)["fee"]

      # Dated: max(80 * 2 * 0.0009, 2 * 0.85) = max(0.144, 1.70) = 1.70
      # Perp (what it used to charge): max(80 * 2 * 0.0003, 2 * 0.15) = 0.30
      expect(fee).to be_within(1e-6).of(1.70)
    end

    it "prices a perp on the perp schedule" do
      # CostModel.perp? is "Coinbase advertised funding for it", i.e. a
      # FundingRate row exists.
      FundingRate.create!(product_id: "BIP-20DEC30-CDE", funding_rate: 0.0001,
        funding_interval_seconds: 3600, funding_time: Time.current,
        observed_at: Time.current)

      fee = service.send(:simulate_order,
        product_id: "BIP-20DEC30-CDE", side: :buy, size: 2, price: 100_000.0)["fee"]

      # Perp: max(100_000 * 2 * 0.0003, 2 * 0.15) = max(60.0, 0.30) = 60.0
      expect(fee).to be_within(1e-6).of(60.0)
    end
  end
end
