require_relative "../../lib/execution/position"

RSpec.describe Execution::Position do
  # Kalshi carries the side in the SIGN of a decimal string: "-5.00" is five
  # contracts of NO, not a negative amount of YES. Reading it as an integer
  # field named "position" -- which is what the docs suggest -- gets nil.
  describe ".from_portfolio" do
    it "reads the signed decimal string into contracts and a side" do
      body = {
        "market_positions" => [
          {"ticker" => "KXHIGHAUS-26AUG04-B97.5", "position_fp" => "-5.00"},
          {"ticker" => "KXHIGHNY-26AUG04-B83.5", "position_fp" => "3.00"}
        ]
      }

      held = described_class.from_portfolio(body)

      expect(held).to eq([
        {ticker: "KXHIGHAUS-26AUG04-B97.5", contracts: 5, side: :no},
        {ticker: "KXHIGHNY-26AUG04-B83.5", contracts: 3, side: :yes}
      ])
    end

    # Rounding UP here invents a contract we do not own, and a close for more
    # than we hold does not flatten -- it opens the opposite side.
    it "floors a fractional holding rather than rounding it up" do
      body = {"market_positions" => [{"ticker" => "KXHIGHNY-26AUG04-B83.5", "position_fp" => "2.75"}]}

      expect(described_class.from_portfolio(body).first[:contracts]).to eq(2)
    end
  end

  describe ".close_intent" do
    # On Kalshi a sell with no position does not fail -- it opens the other
    # side. So "close what I do not hold" must never reach the order client.
    it "refuses when the ticker is not held at all" do
      expect {
        described_class.close_intent(held: [], ticker: "KXHIGHNY-26AUG04-B83.5", contracts: 5, price_cents: 3)
      }.to raise_error(Execution::Position::Flat, /KXHIGHNY-26AUG04-B83.5/)
    end

    # A fat-fingered count must shrink to the holding, not sail past flat and
    # out the other side.
    it "clamps the count down to what is actually held" do
      held = [{ticker: "KXHIGHAUS-26AUG04-B97.5", contracts: 5, side: :no}]

      intent = described_class.close_intent(
        held: held, ticker: "KXHIGHAUS-26AUG04-B97.5", contracts: 9, price_cents: 3
      )

      expect(intent[:contracts]).to eq(5)
    end

    it "leaves a partial close alone when it is smaller than the holding" do
      held = [{ticker: "KXHIGHAUS-26AUG04-B97.5", contracts: 5, side: :no}]

      intent = described_class.close_intent(
        held: held, ticker: "KXHIGHAUS-26AUG04-B97.5", contracts: 2, price_cents: 3
      )

      expect(intent[:contracts]).to eq(2)
    end

    # v2 quotes everything from the YES leg, so there is no "sell NO".
    # Exiting a NO holding means BUYING yes; exiting a YES holding means
    # selling it. Getting this backwards doubles the position instead of
    # closing it.
    it "exits a YES holding by selling and a NO holding by buying" do
      held = [
        {ticker: "KXHIGHAUS-26AUG04-B97.5", contracts: 5, side: :no},
        {ticker: "KXHIGHNY-26AUG04-B83.5", contracts: 3, side: :yes}
      ]

      short = described_class.close_intent(held: held, ticker: "KXHIGHAUS-26AUG04-B97.5", contracts: 5, price_cents: 3)
      long = described_class.close_intent(held: held, ticker: "KXHIGHNY-26AUG04-B83.5", contracts: 3, price_cents: 97)

      expect(short).to eq(ticker: "KXHIGHAUS-26AUG04-B97.5", side: :buy, contracts: 5, price_cents: 3)
      expect(long).to eq(ticker: "KXHIGHNY-26AUG04-B83.5", side: :sell, contracts: 3, price_cents: 97)
    end

    # A settled or fully-closed market can still appear in the portfolio at
    # 0.00. That is flat, and flat must refuse rather than send count: 0.
    it "treats a zero holding as flat" do
      held = [{ticker: "KXHIGHAUS-26AUG04-B97.5", contracts: 0, side: :yes}]

      expect {
        described_class.close_intent(held: held, ticker: "KXHIGHAUS-26AUG04-B97.5", contracts: 5, price_cents: 3)
      }.to raise_error(Execution::Position::Flat)
    end
  end
end
