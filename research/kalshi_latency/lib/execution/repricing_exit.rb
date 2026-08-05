require_relative "order_log"

# Exit on the market's agreement, not on settlement.
#
# A settled-fact position is done the moment the book reprices to the settled
# value: the remaining cents are small exactly where fees are near zero, the
# collateral is freed the same day instead of overnight (the binding
# constraint on a small account), and — the load-bearing part — selling into
# the repriced book pays on MARKET agreement, never on the settlement source.
# METAR-vs-CLI basis risk, the weather track's biggest unverified assumption,
# only exists for positions held to settlement.
module Execution
  class RepricingExit
    # Exit when the remaining edge is this small or less. 3c give-up buys
    # same-day capital recycling and deletes basis risk; the crossing fee at
    # these prices is 0-1c.
    EXIT_EDGE_CENTS = 3

    def initialize(client:, log:, reader:)
      @client = client
      @log = log
      @reader = reader
    end

    # Reads the open positions from the order log, quotes just their tickers,
    # and crosses out of any the market has repriced. Returns the exit intents.
    def check
      open = @log.open_positions
      return [] if open.empty?

      quotes = @reader.quotes(open.map { |p| p["ticker"] }).to_h { |q| [q[:ticker], q] }

      open.filter_map do |position|
        quote = quotes[position["ticker"]]
        next unless quote

        exit_for(position, quote)
      end
    end

    private

    def exit_for(position, quote)
      side, price =
        case position["side"]
        when "ask" # short YES, settles 0: buy back once the offer is near zero
          # An ask of 0 is an empty offer stack, not a free exit -- nothing to cross.
          [:buy, quote[:ask_cents]] if quote[:ask_cents].to_i.between?(1, EXIT_EDGE_CENTS)
        when "bid" # long YES, settles 100: sell once the bid is near par
          [:sell, quote[:bid_cents]] if quote[:bid_cents].to_i.between?(100 - EXIT_EDGE_CENTS, 99)
        end
      return nil unless side

      intent = @client.place(
        ticker: position["ticker"], side: side,
        price_cents: price.to_i, contracts: position["count"].to_f.round
      )
      @log.record(intent.merge(exit: true))
      intent
    end
  end
end
