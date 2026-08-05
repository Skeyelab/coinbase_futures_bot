# What we actually hold, and what it takes to get flat.
#
# Kalshi reports a position as `position_fp` -- a signed DECIMAL STRING, not the
# integer `position` field the docs imply. The sign is the side: "-5.00" is five
# NO contracts, "3.00" is three YES. Reading it as an int gets nil and a nil
# position reads as flat, which is the most dangerous wrong answer available.
module Execution
  module Position
    class Flat < StandardError; end

    module_function

    def from_portfolio(body)
      (body["market_positions"] || []).map do |row|
        size = row["position_fp"].to_f
        {
          ticker: row["ticker"],
          # floor, not round: a fractional holding must never round UP into
          # contracts we do not have, or "close" opens the opposite side.
          contracts: size.abs.floor,
          side: size.negative? ? :no : :yes
        }
      end
    end

    # The only way to build a closing order. Every refusal is loud: a silent
    # nil here becomes a naked sell one caller later.
    def close_intent(held:, ticker:, contracts:, price_cents:)
      position = held.find { |row| row[:ticker] == ticker }
      # A settled market lingers in the portfolio at 0.00. Absent and zero are
      # the same fact -- there is nothing to sell.
      raise Flat, "no position in #{ticker}" if position.nil? || position[:contracts].zero?

      {ticker: ticker, side: :sell, outcome_side: position[:side],
       contracts: [contracts, position[:contracts]].min, price_cents: price_cents}
    end
  end
end
