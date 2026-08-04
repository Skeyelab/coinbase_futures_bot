require_relative "../lib/temp_market"
require_relative "../lib/opportunity"

RSpec.describe Opportunity do
  def bucket
    TempMarket.new(ticker: "KXHIGHNY-26AUG04-B83.5", kind: :between, floor: 83, cap: 84)
  end

  def floor_market
    TempMarket.new(ticker: "KXHIGHNY-26AUG04-T88", kind: :greater, floor: 88, cap: nil)
  end

  describe ".find" do
    # The day already hit 85, so the 83-84 bucket is worth zero. Anyone still
    # bidding 5c for it is paying for a fact the NWS published.
    it "sells a refuted contract that someone is still bidding for" do
      found = described_class.find(market: bucket, running_high: 85, bid_cents: 5, ask_cents: 6)

      expect(found[:side]).to eq(:sell)
      expect(found[:price_cents]).to eq(5)
      expect(found[:gross_cents]).to eq(5)
    end

    it "buys a confirmed contract that someone is still offering below par" do
      found = described_class.find(market: floor_market, running_high: 90, bid_cents: 94, ask_cents: 95)

      expect(found[:side]).to eq(:buy)
      expect(found[:price_cents]).to eq(95)
      expect(found[:gross_cents]).to eq(5)
    end

    it "finds nothing while the day can still go either way" do
      expect(described_class.find(market: bucket, running_high: 79, bid_cents: 40, ask_cents: 41)).to be_nil
    end

    it "finds nothing when a refuted contract is already marked to zero" do
      expect(described_class.find(market: bucket, running_high: 85, bid_cents: 0, ask_cents: 1)).to be_nil
    end

    it "finds nothing when a confirmed contract is already marked to par" do
      expect(described_class.find(market: floor_market, running_high: 90, bid_cents: 99, ask_cents: 100)).to be_nil
    end

    it "reports the edge net of the Kalshi fee" do
      found = described_class.find(market: bucket, running_high: 85, bid_cents: 5, ask_cents: 6)

      # 0.07 x 0.05 x 0.95 x 100 = 0.33c, rounded up to 1c.
      expect(found[:fee_cents]).to eq(1)
      expect(found[:net_cents]).to eq(4)
    end

    it "skips an edge the fee would eat" do
      found = described_class.find(market: bucket, running_high: 85, bid_cents: 1, ask_cents: 2)

      expect(found).to be_nil
    end
  end
end
