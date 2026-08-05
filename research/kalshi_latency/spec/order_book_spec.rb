require_relative "../lib/order_book"

RSpec.describe OrderBook do
  # Kalshi quotes two BID books, not a bid and an ask. A NO bid at 62c is
  # someone willing to pay 62c for NO, which is the same as offering YES at 38c.
  # Reading no_dollars as if it were an ask ladder would report asks below the
  # bid and invert every capacity number.
  let(:payload) do
    {
      "orderbook_fp" => {
        "yes_dollars" => [["0.3200", "103.00"], ["0.3500", "102.29"], ["0.3700", "7.00"]],
        "no_dollars" => [["0.5500", "119.00"], ["0.6000", "16.21"], ["0.6200", "153.74"]]
      }
    }
  end

  describe ".parse" do
    it "reads the best yes bid from the top of the yes ladder" do
      book = described_class.parse(payload)

      expect(book.best_bid_cents).to eq(37.0)
      expect(book.best_bid_size).to be_within(1e-6).of(7.0)
    end

    # THE INVERSION. A 62c NO bid is a 38c YES offer. Read straight through it
    # would look like a 62c ask against a 37c bid -- a 25c spread on a market
    # that is actually one cent wide.
    it "turns the no-side bids into yes asks" do
      book = described_class.parse(payload)

      expect(book.best_ask_cents).to eq(38.0)
      expect(book.best_ask_size).to be_within(1e-6).of(153.74)
      expect(book.spread_cents).to eq(1.0)
    end

    it "orders each side from the touch outward" do
      book = described_class.parse(payload)

      expect(book.bids.map(&:price_cents)).to eq([37.0, 35.0, 32.0])
      expect(book.asks.map(&:price_cents)).to eq([38.0, 40.0, 45.0])
    end

    # The whole point of authenticating. Top-of-book showed 7 contracts; the
    # real bid side within 5c is 112. A capacity verdict built on the touch
    # alone would be wrong by 16x here.
    it "sums real depth within a band of the touch" do
      book = described_class.parse(payload)

      expect(book.bid_depth_within(0)).to be_within(1e-6).of(7.0)
      expect(book.bid_depth_within(2)).to be_within(1e-6).of(109.29)
      expect(book.bid_depth_within(5)).to be_within(1e-6).of(212.29)
    end

    it "sums ask depth outward from its own touch" do
      book = described_class.parse(payload)

      expect(book.ask_depth_within(0)).to be_within(1e-6).of(153.74)
      expect(book.ask_depth_within(2)).to be_within(1e-6).of(169.95)
      expect(book.ask_depth_within(7)).to be_within(1e-6).of(288.95)
    end

    it "reports nothing rather than guessing on an empty book" do
      book = described_class.parse({"orderbook_fp" => {"yes_dollars" => [], "no_dollars" => []}})

      expect(book.best_bid_cents).to be_nil
      expect(book.best_ask_cents).to be_nil
      expect(book.spread_cents).to be_nil
      expect(book.bid_depth_within(5)).to eq(0.0)
    end

    it "survives a payload with no orderbook at all" do
      expect { described_class.parse({}) }.not_to raise_error
      expect(described_class.parse({}).best_bid_cents).to be_nil
      expect(described_class.parse(nil).best_bid_cents).to be_nil
    end

    it "drops zero-priced rungs rather than treating them as a touch" do
      book = described_class.parse({"orderbook_fp" => {
        "yes_dollars" => [["0.0000", "500.00"], ["0.3000", "5.00"]], "no_dollars" => []
      }})

      expect(book.best_bid_cents).to eq(30.0)
      expect(book.bids.size).to eq(1)
    end
  end
end
