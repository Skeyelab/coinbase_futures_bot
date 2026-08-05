require "json"
require "securerandom"
require_relative "../kalshi_signer"
require_relative "http_transport"

# The write path. Deliberately a separate class from KalshiClient: the read
# client's guarantee -- "a misused key cannot place a trade through it" -- stays
# true because ordering lives here and nowhere else.
#
# Dry-run is the default and the constructor makes live mode loud.
module Execution
  class OrderClient
    class LiveRefused < StandardError; end

    class BadOrder < StandardError; end

    class NotLive < StandardError; end

    # Not symmetric, and the asymmetry is the venue's, not a typo: creating and
    # cancelling go through /portfolio/events/orders, reading one back goes
    # through /portfolio/orders.
    ORDERS_PATH = "/portfolio/events/orders".freeze
    READ_ORDER_PATH = "/portfolio/orders".freeze
    # Everything is quoted from the YES leg. bid buys YES, ask sells YES;
    # selling YES is how you exit a NO holding (economically buying NO at
    # 1 - price), so there is no yes/no field on an order any more.
    BOOK_SIDE = {buy: "bid", sell: "ask"}.freeze
    API_PREFIX = "/trade-api/v2".freeze
    # 25 contracts at worst-case collateral is ~$25 of a $250 account. A cap
    # this small cannot be emptied by one wrong episode, which is the point.
    DEFAULT_MAX_CONTRACTS = 25

    # Going live takes two independent switches: live: true in code AND
    # KALSHI_LIVE=1 in the environment. Either alone stays dry. One flag can be
    # left on by mistake; two must be thrown on purpose.
    def initialize(transport:, live: false, env: ENV, signer: nil, max_contracts: DEFAULT_MAX_CONTRACTS)
      @transport = transport
      @signer = signer
      @max_contracts = max_contracts
      @live = live && env["KALSHI_LIVE"] == "1"
      raise LiveRefused, "live: true but KALSHI_LIVE is not 1" if live && !@live
    end

    def live?
      @live
    end

    # Takes an Opportunity.find hash -- or a Position.close_intent -- and
    # returns the order intent. v2 quotes every order from the YES leg: :buy
    # becomes a bid, :sell an ask. There is no yes/no field and no action
    # field, so exiting a NO holding is a BID, not a sell.
    def place(opportunity)
      validate!(opportunity)
      order = {
        ticker: opportunity[:ticker],
        side: BOOK_SIDE.fetch(opportunity[:side]),
        # Both are STRINGS on v2, and price is fixed-point dollars rather than
        # integer cents. 12 sent as a number is not 12c, it is rejected.
        count: format("%.2f", opportunity[:contracts]),
        price: format("%.4f", opportunity[:price_cents] / 100.0),
        time_in_force: "good_till_canceled",
        # Required by v2 -- omitting it is a 400 missing_parameters.
        self_trade_prevention_type: "taker_at_cross",
        client_order_id: SecureRandom.uuid
      }

      return order.merge(mode: "dry_run") unless live?

      response = send_signed("POST", ORDERS_PATH, body: JSON.generate(order))
      # v2 answers 201 with a FLAT body -- {order_id, client_order_id,
      # fill_count, remaining_count}. There is no "order" wrapper to dig into,
      # and a nil order_id leaves a live order nobody can watch or cancel.
      order.merge(mode: "live", order_id: response.fetch("order_id"))
    end

    # The venue's own view of one order. Reading order state belongs with
    # placing and cancelling rather than in the read client: the read client's
    # guarantee is that it knows nothing about orders at all.
    def order(order_id)
      raise NotLive, "no order #{order_id} exists in dry-run" unless live?

      send_signed("GET", "#{READ_ORDER_PATH}/#{order_id}")["order"]
    rescue HttpTransport::RequestFailed => e
      # A just-created order 404s for a beat before the venue serves it back.
      # nil means "not yet"; anything else is a real failure and must not be
      # swallowed into something a caller reads as a resting order.
      raise unless e.message.include?("not_found")

      nil
    end

    # Pulling a resting order. Gate item #3 needs this as much as placing does:
    # an order left resting forever is neither a fill nor a miss, and it scores
    # as neither.
    def cancel(order_id)
      intent = {action: "cancel", order_id: order_id}
      return intent.merge(mode: "dry_run") unless live?

      send_signed("DELETE", "#{ORDERS_PATH}/#{order_id}")
      intent.merge(mode: "live")
    end

    private

    # One place where a signature is produced. Kalshi signs
    # <timestamp_ms><METHOD><path> and the path carries no query string --
    # including one gives a bare 401 that names neither half.
    def send_signed(method, path, body: nil)
      @transport.call(
        method: method,
        path: path,
        headers: @signer.headers_for(method: method, path: "#{API_PREFIX}#{path}"),
        body: body
      )
    end

    def validate!(opportunity)
      price = opportunity[:price_cents]
      count = opportunity[:contracts]
      side = opportunity[:side]

      raise BadOrder, "price #{price} off the 1-99 board" unless (1..99).cover?(price)
      raise BadOrder, "count #{count} outside 1..#{@max_contracts}" unless (1..@max_contracts).cover?(count)
      raise BadOrder, "side #{side} is not buy or sell" unless [:buy, :sell].include?(side)
    end
  end
end
