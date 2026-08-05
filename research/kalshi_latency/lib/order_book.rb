# A Kalshi order book, normalised to YES prices in cents.
#
# Kalshi publishes two BID ladders rather than a bid and an ask. `yes_dollars`
# is what people will pay for YES; `no_dollars` is what people will pay for NO.
# A NO bid at 62c is the same thing as an offer of YES at 38c, so the ask side
# has to be derived by inverting. Reading no_dollars as an ask ladder directly
# would report asks below the bid and invert every capacity number this
# experiment exists to measure.
#
# Both ladders arrive ascending by price, so the best YES bid is the LAST entry
# of yes_dollars, and the best (lowest) YES ask comes from the LAST entry of
# no_dollars.
class OrderBook
  Level = Struct.new(:price_cents, :size)

  attr_reader :bids, :asks

  # bids: descending by price. asks: ascending. Both are YES-denominated.
  def initialize(bids, asks)
    @bids = bids
    @asks = asks
  end

  def self.parse(payload)
    book = payload.is_a?(Hash) ? (payload["orderbook_fp"] || {}) : {}

    bids = ladder(book["yes_dollars"]).sort_by { |l| -l.price_cents }
    # 100 - price flips a NO bid into the YES offer it is equivalent to.
    asks = ladder(book["no_dollars"])
      .map { |l| Level.new((100.0 - l.price_cents).round(4), l.size) }
      .sort_by(&:price_cents)

    new(bids, asks)
  end

  def self.ladder(rows)
    Array(rows).filter_map do |price, size|
      cents = (price.to_f * 100).round(4)
      next if cents <= 0

      Level.new(cents, size.to_f)
    end
  end

  def best_bid_cents = bids.first&.price_cents
  def best_bid_size = bids.first&.size
  def best_ask_cents = asks.first&.price_cents
  def best_ask_size = asks.first&.size

  def spread_cents
    return nil if best_bid_cents.nil? || best_ask_cents.nil?

    (best_ask_cents - best_bid_cents).round(4)
  end

  # Contracts available within `cents` of the touch. This is the capacity
  # number: top-of-book alone understates what a taker could actually lift.
  def bid_depth_within(cents)
    depth(bids, best_bid_cents) { |p, top| p >= top - cents }
  end

  def ask_depth_within(cents)
    depth(asks, best_ask_cents) { |p, top| p <= top + cents }
  end

  private

  def depth(levels, top)
    return 0.0 if top.nil?

    levels.select { |l| yield(l.price_cents, top) }.sum(&:size)
  end
end
