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
  # Kalshi charges ceil(0.07 x C x P x (1-P)) on the WHOLE ORDER, rounded up
  # once -- not per contract.
  #
  # The distinction is not cosmetic. Charging per contract and multiplying
  # overstates the cost roughly linearly with size, and at the tails it deletes
  # real opportunities: a 1c gross edge nets zero under the per-contract model
  # and gets filtered out, when 20 contracts of it is 20c against a 2c fee.
  #
  # Quadratic in price, so it is largest mid-book and near-free at the tails --
  # which is exactly where settled contracts trade.
  def self.fee_cents(price_cents, contracts = 1)
    p = price_cents / 100.0
    # round(6) before ceil: 0.07 x 100 x 0.5 x 0.5 x 100 is exactly 175 cents but
    # floats render it as 175.00000000000003, which would ceil to 176 and charge
    # a phantom cent on every mid-book order.
    (0.07 * contracts * p * (1 - p) * 100).round(6).ceil
  end

  # `observed` is whatever running extreme the market ratchets on: a daily
  # high in degrees for a temperature bucket, a running minimum in dollars for
  # a one-touch. Opportunity does not need to know which -- both answer
  # status_given, and that is the entire shared contract.
  def self.find(market:, observed:, bid_cents:, ask_cents:, contracts: 1)
    side, price, edge =
      case market.status_given(observed)
      when :refuted then [:sell, bid_cents, bid_cents]         # worth 0, someone bids
      when :confirmed then [:buy, ask_cents, 100 - ask_cents]  # worth 100, someone offers
      else return nil
      end

    size = contracts.to_i
    gross = edge * size
    fee = fee_cents(price, size)
    net = gross - fee
    return nil unless net > 0

    {
      ticker: market.ticker,
      side: side,
      price_cents: price,
      contracts: size,
      edge_cents: edge,
      gross_cents: gross,
      fee_cents: fee,
      net_cents: net
    }
  end
end
