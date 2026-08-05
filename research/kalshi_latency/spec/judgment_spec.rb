require_relative "../lib/judgment"

RSpec.describe Judgment do
  describe ".brier" do
    it "scores one probabilistic call against its outcome" do
      # 0.8 on YES, settled yes: (0.8 - 1)^2 = 0.04
      expect(described_class.brier([{prob: 0.8, settled_yes: true}])).to be_within(1e-9).of(0.04)
    end
  end

  describe ".paper_trade" do
    it "sells when the book prices YES far above our probability" do
      # We say 10%, the book bids 30c for YES. Sell edge 20c/contract,
      # gross 500c, fee ceil(0.07 x 25 x .30 x .70 x 100) = 37c.
      trade = described_class.paper_trade(prob: 0.10, bid_cents: 30, ask_cents: 32, contracts: 25)

      expect(trade).to eq(side: :sell, price_cents: 30, contracts: 25, ev_cents: 463)
    end

    it "stays out when the edge exists but the fee eats it" do
      # Fair 29 vs bid 30: 1c edge on one contract, fee 2c. Not a trade.
      trade = described_class.paper_trade(prob: 0.29, bid_cents: 30, ask_cents: 32, contracts: 1)

      expect(trade).to be_nil
    end

    it "stays out when the market already agrees with us" do
      trade = described_class.paper_trade(prob: 0.31, bid_cents: 30, ask_cents: 32, contracts: 25)

      expect(trade).to be_nil
    end
  end

  describe ".scorecard" do
    it "compares our calibration to the market's and totals the paper PnL" do
      calls = [
        # We say 10%, book 30/32, settles no: we beat the market and the
        # implied sell (30c x 25 - 37 fee) collects 713.
        {prob: 0.10, bid_cents: 30, ask_cents: 32, contracts: 25, settled_yes: false},
        # We say 56%, book 55/58, settles yes: fair 56 sits inside the
        # spread, no trade -- but the call still counts toward calibration.
        {prob: 0.56, bid_cents: 55, ask_cents: 58, contracts: 25, settled_yes: true}
      ]

      card = described_class.scorecard(calls)

      expect(card[:n]).to eq(2)
      # ours: ((0.10-0)^2 + (0.56-1)^2)/2 = 0.1018
      expect(card[:ours_brier]).to be_within(1e-9).of(0.1018)
      # market mid 31c and 56.5c: ((0.31-0)^2 + (0.565-1)^2)/2 = 0.1426625
      expect(card[:market_brier]).to be_within(1e-9).of(0.1426625)
      expect(card[:paper_pnl_cents]).to eq(713)
      expect(card[:trades]).to eq(1)
    end
  end

  describe ".settle" do
    it "pays a winning sell its premium net of fee" do
      trade = {side: :sell, price_cents: 30, contracts: 25}

      # Sold YES at 30, settled no: keep 30 x 25 = 750, minus 37 fee.
      expect(described_class.settle(trade, settled_yes: false)).to eq(713)
    end

    it "charges a losing sell the full payout plus fee" do
      trade = {side: :sell, price_cents: 30, contracts: 25}

      # Sold YES at 30, settled yes: pay (100-30) x 25 = 1750, plus 37 fee.
      expect(described_class.settle(trade, settled_yes: true)).to eq(-1787)
    end

    it "pays a winning buy its edge net of fee" do
      trade = {side: :buy, price_cents: 94, contracts: 50}

      # Bought at 94, settled yes: win (100-94) x 50 = 300, fee at 94c is
      # ceil(0.07 x 50 x .94 x .06 x 100) = 20.
      expect(described_class.settle(trade, settled_yes: true)).to eq(280)
    end

    it "charges a losing buy its stake plus fee" do
      trade = {side: :buy, price_cents: 94, contracts: 50}

      expect(described_class.settle(trade, settled_yes: false)).to eq(-4720)
    end
  end
end
