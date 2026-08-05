require_relative "../lib/temp_market"
require_relative "../lib/touch_market"
require_relative "../lib/opportunity"

RSpec.describe Opportunity do
  def bucket
    TempMarket.new(ticker: "KXHIGHNY-26AUG04-B83.5", kind: :between, floor: 83, cap: 84)
  end

  def floor_market
    TempMarket.new(ticker: "KXHIGHNY-26AUG04-T88", kind: :greater, floor: 88, cap: nil)
  end

  # Kalshi charges ceil(0.07 x C x P x (1-P)) on the WHOLE ORDER, rounded up
  # once. Charging it per contract and multiplying overstates the cost badly at
  # size, and at the tails it wipes out real opportunities entirely: a 1c gross
  # edge nets zero under the per-contract model and gets filtered away.
  # The generalisation. Opportunity was written against temperature buckets and
  # must price a one-touch without knowing anything about it -- both markets
  # answer status_given, and that is the whole contract between them.
  describe "any ratchet market" do
    def touched_below
      TouchMarket.new(ticker: "KXBTCMINMON-BTC-26AUG31-600000", direction: :below, threshold: 60_000.0)
    end

    it "buys a one-touch the market has already settled but not repriced" do
      # BTC printed 59,900, so the contract is worth 100 and still offers at 94.
      found = described_class.find(market: touched_below, observed: 59_900.0,
        bid_cents: 93, ask_cents: 94, contracts: 50)

      expect(found[:side]).to eq(:buy)
      expect(found[:price_cents]).to eq(94)
      expect(found[:edge_cents]).to eq(6)
      expect(found[:gross_cents]).to eq(300)
    end

    it "finds nothing in a one-touch that has not touched" do
      expect(described_class.find(market: touched_below, observed: 61_000.0,
        bid_cents: 40, ask_cents: 41, contracts: 50)).to be_nil
    end

    # A one-touch is never worth zero before expiry, so there is never a short
    # to take. Anything that reported one would be selling a live outcome.
    it "never proposes selling a one-touch" do
      [90_000.0, 61_000.0, 59_000.0].each do |observed|
        found = described_class.find(market: touched_below, observed: observed,
          bid_cents: 40, ask_cents: 41, contracts: 50)
        expect(found&.dig(:side)).not_to eq(:sell)
      end
    end
  end

  describe ".fee_cents" do
    it "rounds one contract up to the minimum cent" do
      # 0.07 x 1 x 0.99 x 0.01 = $0.000693 -> 1c
      expect(described_class.fee_cents(99, 1)).to eq(1)
    end

    it "charges the order once rather than once per contract" do
      # 0.07 x 5 x 0.99 x 0.01 = $0.003465 -> still 1c for the whole order
      expect(described_class.fee_cents(99, 5)).to eq(1)
      # 0.07 x 20 x 0.99 x 0.01 = $0.01386 -> 2c
      expect(described_class.fee_cents(99, 20)).to eq(2)
    end

    # Quadratic in price: most expensive at 50c, ~13x cheaper at the tails,
    # which is exactly where settled contracts trade.
    it "peaks in the middle of the book and is far cheaper at the tails" do
      expect(described_class.fee_cents(50, 100)).to eq(175)
      expect(described_class.fee_cents(2, 100)).to eq(14)
      expect(described_class.fee_cents(98, 100)).to eq(14)
    end

    # 0.07 x 100 x 0.5 x 0.5 x 100 is exactly 175 cents. In floating point it
    # renders as 175.00000000000003, and a bare ceil charges 176.
    it "does not invent a cent from floating point error" do
      expect(described_class.fee_cents(50, 100)).not_to eq(176)
    end

    it "defaults to a single contract" do
      expect(described_class.fee_cents(50)).to eq(described_class.fee_cents(50, 1))
    end
  end

  describe ".find" do
    # The day already hit 85, so the 83-84 bucket is worth zero. Anyone still
    # bidding 5c for it is paying for a fact the NWS published.
    it "sells a refuted contract that someone is still bidding for" do
      found = described_class.find(market: bucket, observed: 85, bid_cents: 5, ask_cents: 6)

      expect(found[:side]).to eq(:sell)
      expect(found[:price_cents]).to eq(5)
      expect(found[:gross_cents]).to eq(5)
    end

    it "buys a confirmed contract that someone is still offering below par" do
      found = described_class.find(market: floor_market, observed: 90, bid_cents: 94, ask_cents: 95)

      expect(found[:side]).to eq(:buy)
      expect(found[:price_cents]).to eq(95)
      expect(found[:gross_cents]).to eq(5)
    end

    it "finds nothing while the day can still go either way" do
      expect(described_class.find(market: bucket, observed: 79, bid_cents: 40, ask_cents: 41)).to be_nil
    end

    it "finds nothing when a refuted contract is already marked to zero" do
      expect(described_class.find(market: bucket, observed: 85, bid_cents: 0, ask_cents: 1)).to be_nil
    end

    it "finds nothing when a confirmed contract is already marked to par" do
      expect(described_class.find(market: floor_market, observed: 90, bid_cents: 99, ask_cents: 100)).to be_nil
    end

    it "reports the edge net of the Kalshi fee" do
      found = described_class.find(market: bucket, observed: 85, bid_cents: 5, ask_cents: 6)

      # 0.07 x 0.05 x 0.95 x 100 = 0.33c, rounded up to 1c.
      expect(found[:fee_cents]).to eq(1)
      expect(found[:net_cents]).to eq(4)
    end

    it "skips an edge the fee would eat" do
      found = described_class.find(market: bucket, observed: 85, bid_cents: 1, ask_cents: 2)

      expect(found).to be_nil
    end

    # The false negative the per-contract model created. Twenty contracts of a
    # 1c edge is 20c gross against a 2c order fee -- clearly worth taking, and
    # the old model reported it as exactly break-even and discarded it.
    it "keeps a thin edge that only pays once it is sized" do
      found = described_class.find(market: floor_market, observed: 90,
        bid_cents: 98, ask_cents: 99, contracts: 20)

      expect(found[:gross_cents]).to eq(20)
      expect(found[:fee_cents]).to eq(2)
      expect(found[:net_cents]).to eq(18)
      expect(found[:contracts]).to eq(20)
    end

    # No size means no position. This falls out of the net check rather than a
    # separate guard, so it is pinned here to keep it from regressing quietly.
    it "finds nothing when there is no size to trade" do
      expect(described_class.find(market: bucket, observed: 85,
        bid_cents: 5, ask_cents: 6, contracts: 0)).to be_nil
      expect(described_class.find(market: bucket, observed: 85,
        bid_cents: 5, ask_cents: 6, contracts: -3)).to be_nil
    end

    it "reports totals for the position, not per contract" do
      found = described_class.find(market: bucket, observed: 85,
        bid_cents: 5, ask_cents: 6, contracts: 10)

      expect(found[:price_cents]).to eq(5)
      expect(found[:gross_cents]).to eq(50)
      # 0.07 x 10 x 0.05 x 0.95 = $0.03325 -> 4c
      expect(found[:fee_cents]).to eq(4)
      expect(found[:net_cents]).to eq(46)
    end
  end
end
