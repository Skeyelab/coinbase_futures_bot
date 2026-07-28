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
      # BIP is 0.01 BTC per contract — the quote price is NOT the notional.
      allow(Trading::ContractSizeResolver).to receive(:for_product).and_return(0.01)

      fee = service.send(:simulate_order,
        product_id: "BIP-20DEC30-CDE", side: :buy, size: 2, price: 100_000.0)["fee"]

      # notional = 100_000 * 0.01 * 2 = $2,000
      # max(2_000 * 0.0003, 2 * 0.15) = max(0.60, 0.30) = 0.60
      expect(fee).to be_within(1e-6).of(0.60)
    end

    # The #486 calibration rehearsal measured a 300 bps taker rate against a
    # modeled 3 bps — exactly 100x, which is BIP's contract_size of 0.01. The
    # fee was being charged on the quote price rather than on notional, so a
    # 1-contract BIP fill priced as if it were a whole bitcoin.
    it "charges the fee on notional, not on the quote price" do
      FundingRate.create!(product_id: "BIP-20DEC30-CDE", funding_rate: 0.0001,
        funding_interval_seconds: 3600, funding_time: Time.current,
        observed_at: Time.current)
      allow(Trading::ContractSizeResolver).to receive(:for_product).and_return(0.01)

      fee = service.send(:simulate_order,
        product_id: "BIP-20DEC30-CDE", side: :buy, size: 1, price: 63_745.0)["fee"]

      # notional = 63_745 * 0.01 = $637.45; 3 bps of that is $0.191235, and the
      # $0.15/contract floor does not bind. Charging on the raw price gave
      # $19.1235 — the 100x the calibration run surfaced.
      expect(fee).to be_within(1e-6).of(0.191235)
    end
  end
end
