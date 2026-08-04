# A contract the weather has already settled, that the book has not.
#
# This is the trade the whole thesis is about, and it involves no forecasting.
# Once the day's high passes the top of a bucket, that bucket is worth zero.
# Anyone still bidding for it is paying for a fact the NWS already published.
# Symmetrically, once the day reaches a floor market's strike, it is worth 100
# and anyone still offering it below that is selling a settled outcome.
#
# We are not predicting the weather. We are reading a public number faster than
# the person on the other side.
module Opportunity
  # Kalshi charges 0.07 x P x (1-P) per contract, rounded up to the cent. It is
  # tiny at the tails, which is exactly where settled contracts trade.
  def self.fee_cents(price_cents)
    p = price_cents / 100.0
    (0.07 * p * (1 - p) * 100).ceil
  end

  def self.find(market:, running_high:, bid_cents:, ask_cents:)
    side, price, gross =
      case market.status_given(running_high)
      when :refuted then [:sell, bid_cents, bid_cents]         # worth 0, someone bids
      when :confirmed then [:buy, ask_cents, 100 - ask_cents]  # worth 100, someone offers
      else return nil
      end

    fee = fee_cents(price)
    net = gross - fee
    return nil unless net > 0

    {
      ticker: market.ticker,
      side: side,
      price_cents: price,
      gross_cents: gross,
      fee_cents: fee,
      net_cents: net
    }
  end
end
