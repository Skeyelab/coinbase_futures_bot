require_relative "../lib/watchlist"

def market(ticker: "KXTEST-01", bid: "0.40", ask: "0.42", vol24: "5000", bid_size: "500")
  {
    "ticker" => ticker,
    "title" => "Test market",
    "yes_bid_dollars" => bid,
    "yes_ask_dollars" => ask,
    "volume_24h_fp" => vol24,
    "yes_bid_size_fp" => bid_size
  }
end

RSpec.describe Watchlist do
  describe ".select_from" do
    it "keeps a liquid two-sided market" do
      picked = described_class.select_from([market], min_volume_24h: 100)

      expect(picked.map { |m| m[:ticker] }).to eq(["KXTEST-01"])
    end

    it "drops auto-generated combination markets even when they look liquid" do
      combo = market(ticker: "KXMVECROSSCATEGORY-S2026-ABC")

      expect(described_class.select_from([combo], min_volume_24h: 100)).to be_empty
    end

    it "drops a market quoted on one side only" do
      one_sided = market(bid: "0.00", ask: "0.42")

      expect(described_class.select_from([one_sided], min_volume_24h: 100)).to be_empty
    end

    it "drops a market whose spread is wider than we could ever trade through" do
      wide = market(bid: "0.20", ask: "0.60")

      expect(described_class.select_from([wide], min_volume_24h: 100, max_spread_cents: 10)).to be_empty
    end

    it "keeps a market sitting exactly on the spread ceiling" do
      exact = market(bid: "0.40", ask: "0.50")

      expect(described_class.select_from([exact], min_volume_24h: 100, max_spread_cents: 10).size).to eq(1)
    end

    # bid=0 with a tight spread slips past the spread guard, so the one-sided
    # check has to stand on its own.
    it "drops an unbid market even when its spread looks tight" do
      no_bid = market(bid: "0.00", ask: "0.05")

      expect(described_class.select_from([no_bid], min_volume_24h: 100, max_spread_cents: 10)).to be_empty
    end

    it "drops a market below the volume floor" do
      quiet = market(vol24: "99")

      expect(described_class.select_from([quiet], min_volume_24h: 100)).to be_empty
    end

    it "keeps a market sitting exactly on the volume floor" do
      floor = market(vol24: "100")

      expect(described_class.select_from([floor], min_volume_24h: 100).size).to eq(1)
    end

    it "ranks the busiest markets first and honours the limit" do
      busy = market(ticker: "BUSY", vol24: "9000")
      mid = market(ticker: "MID", vol24: "5000")
      slow = market(ticker: "SLOW", vol24: "1000")

      picked = described_class.select_from([slow, busy, mid], min_volume_24h: 100, limit: 2)

      expect(picked.map { |m| m[:ticker] }).to eq(%w[BUSY MID])
    end

    it "converts dollar quotes into cents" do
      picked = described_class.select_from([market(bid: "0.40", ask: "0.42")], min_volume_24h: 100).first

      expect(picked[:bid_cents]).to be_within(0.001).of(40.0)
      expect(picked[:ask_cents]).to be_within(0.001).of(42.0)
      expect(picked[:spread_cents]).to be_within(0.001).of(2.0)
    end
  end
end
