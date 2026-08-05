require_relative "opportunity"

# The judgment track: probabilistic calls scored against settlement.
#
# The ratchet track deals in certainties -- a settled fact is 0 or 100 and the
# only question is whether the arithmetic was right. This track deals in
# estimates, so the standard changes: a model is good when its probabilities
# are better CALIBRATED than the market's price, measured by Brier score, and
# when the paper trades those probabilities imply are profitable after fees.
# Neither claim is allowed to rest on feel. That is the whole point.
module Judgment
  # Mean squared distance between stated probability and what happened.
  # Lower is better. 0.25 is what always saying 50% scores.
  def self.brier(calls)
    return nil if calls.empty?

    calls.sum { |c| (c[:prob] - (c[:settled_yes] ? 1.0 : 0.0))**2 } / calls.size
  end

  # The trade our probability implies against the current book, or nil.
  # Buying pays the ask and wins when YES; selling collects the bid and wins
  # when NO. Positive expected value AFTER the fee or no trade at all.
  def self.paper_trade(prob:, bid_cents:, ask_cents:, contracts:)
    fair = prob * 100

    side, price, edge =
      if fair > ask_cents
        [:buy, ask_cents, fair - ask_cents]
      elsif fair < bid_cents
        [:sell, bid_cents, bid_cents - fair]
      else
        return nil
      end

    ev = (edge * contracts).round - Opportunity.fee_cents(price, contracts)
    return nil unless ev > 0

    {side: side, price_cents: price, contracts: contracts, ev_cents: ev}
  end

  # What the trade actually made once the market settled, fee included.
  # A sell collects its premium when NO and pays the full 100 when YES;
  # a buy is the mirror. The fee is paid either way -- it was paid at entry.
  def self.settle(trade, settled_yes:)
    price = trade[:price_cents]
    count = trade[:contracts]
    fee = Opportunity.fee_cents(price, count)

    won = (trade[:side] == :buy) == settled_yes
    gross =
      if trade[:side] == :buy
        won ? (100 - price) * count : -price * count
      else
        won ? price * count : -(100 - price) * count
      end

    gross - fee
  end

  # The gate view: are our probabilities better calibrated than the book's
  # mid, and do the trades they imply make money on paper? Every settled call
  # counts toward calibration whether or not it implied a trade -- scoring
  # only the trades is how a model looks better than it is.
  def self.scorecard(calls)
    market_calls = calls.map { |c|
      c.merge(prob: (c[:bid_cents] + c[:ask_cents]) / 200.0)
    }

    trades = calls.filter_map { |c|
      trade = paper_trade(prob: c[:prob], bid_cents: c[:bid_cents],
        ask_cents: c[:ask_cents], contracts: c[:contracts])
      trade && settle(trade, settled_yes: c[:settled_yes])
    }

    {
      n: calls.size,
      ours_brier: brier(calls),
      market_brier: brier(market_calls),
      paper_pnl_cents: trades.sum,
      trades: trades.size
    }
  end
end
