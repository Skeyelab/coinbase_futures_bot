require_relative "../lib/trade_ledger"

RSpec.describe TradeLedger do
  def fill(ticker, action: "buy", side: "no", count: 5, price: 99)
    {"ticker" => ticker, "action" => action, "side" => side,
     "count_fp" => count.to_s, "no_price_dollars" => (price / 100.0).to_s,
     "yes_price_dollars" => ((100 - price) / 100.0).to_s,
     "fee_cost" => "0.0027", "created_time" => "2026-08-04T19:34:14Z"}
  end

  describe ".classify" do
    # A trade counts as gate evidence only if the SYSTEM called it beforehand.
    # Deciding after the fact which trades were "really" the strategy is how a
    # discretionary run gets laundered into a backtest.
    it "counts a fill the system had already flagged as settled-fact evidence" do
      classified = described_class.classify(
        [fill("KXHIGHAUS-26AUG04-B97.5")],
        called_tickers: ["KXHIGHAUS-26AUG04-B97.5"]
      )

      expect(classified.first[:track]).to eq(:settled_fact)
    end

    it "counts an uncalled fill as directional" do
      classified = described_class.classify(
        [fill("KXBTCD-26AUG0417-T63999.99", side: "yes")],
        called_tickers: ["KXHIGHAUS-26AUG04-B97.5"]
      )

      expect(classified.first[:track]).to eq(:directional)
    end

    # The same ticker can be either. Buying a bucket the day has already
    # refuted is arithmetic; buying it at dawn is a forecast. Only the prior
    # call tells them apart, so an empty call list makes everything directional
    # -- including trades that later look obvious.
    it "calls everything directional when nothing was called in advance" do
      classified = described_class.classify(
        [fill("KXHIGHAUS-26AUG04-B97.5"), fill("KXBTCD-26AUG0417-T63999.99")],
        called_tickers: []
      )

      expect(classified.map { |t| t[:track] }).to all(eq(:directional))
    end

    it "carries the fill detail through for P&L" do
      classified = described_class.classify(
        [fill("KXHIGHAUS-26AUG04-B97.5", count: 5, price: 99)],
        called_tickers: ["KXHIGHAUS-26AUG04-B97.5"]
      ).first

      expect(classified[:count]).to eq(5)
      expect(classified[:price_cents]).to eq(99)
      expect(classified[:side]).to eq("no")
    end

    # Kalshi returns count_fp and *_price_dollars, not the bare field names the
    # docs imply. Reading the wrong keys silently reports every fill as 0 @ 0c.
    it "reads the side-appropriate price from the dollars fields" do
      yes_fill = {"ticker" => "X", "side" => "yes", "action" => "buy",
                  "count_fp" => "2.00", "yes_price_dollars" => "0.9600",
                  "no_price_dollars" => "0.0400", "fee_cost" => "0.0027"}

      classified = described_class.classify([yes_fill], called_tickers: []).first

      expect(classified[:price_cents]).to eq(96)
      expect(classified[:count]).to eq(2)
      expect(classified[:fee_cents]).to eq(0.27)
    end

    it "survives no fills at all" do
      expect(described_class.classify([], called_tickers: ["X"])).to eq([])
      expect(described_class.classify(nil, called_tickers: nil)).to eq([])
    end
  end

  describe "the two tracks" do
    let(:classified) do
      described_class.classify(
        [fill("KXHIGHAUS-26AUG04-B97.5"), fill("KXBTCD-26AUG0417-T63999.99", side: "yes")],
        called_tickers: ["KXHIGHAUS-26AUG04-B97.5"]
      )
    end

    # The whole reason this file exists. A run of good directional calls must
    # not make the settled-fact edge look real when it has not been tested.
    it "keeps directional trades out of the gate evidence" do
      expect(described_class.gate_evidence(classified).map { |t| t[:ticker] })
        .to eq(["KXHIGHAUS-26AUG04-B97.5"])
      expect(described_class.directional(classified).map { |t| t[:ticker] })
        .to eq(["KXBTCD-26AUG0417-T63999.99"])
    end

    it "puts every trade in exactly one track" do
      expect(described_class.gate_evidence(classified).size +
             described_class.directional(classified).size).to eq(classified.size)
    end
  end
end
