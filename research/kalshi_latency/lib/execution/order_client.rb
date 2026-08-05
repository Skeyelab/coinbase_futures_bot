require "json"
require "securerandom"
require_relative "../kalshi_signer"

# The write path. Deliberately a separate class from KalshiClient: the read
# client's guarantee -- "a misused key cannot place a trade through it" -- stays
# true because ordering lives here and nowhere else.
#
# Dry-run is the default and the constructor makes live mode loud.
module Execution
  class OrderClient
    class LiveRefused < StandardError; end

    class BadOrder < StandardError; end

    ORDERS_PATH = "/portfolio/orders".freeze
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

    # Takes an Opportunity.find hash and returns the order intent.
    # Kalshi's order API wants action (buy/sell) + side (yes/no) + a price for
    # that side. We always quote in YES terms, so side is always "yes":
    # selling a refuted contract is action=sell, buying a confirmed one is
    # action=buy.
    def place(opportunity)
      validate!(opportunity)
      # Scanning quotes everything in YES terms, so YES is the default. Closing
      # a NO holding is the exception, and it must be priced in no_price:
      # sending 3c as yes_price on a NO order asks for 97c and crosses the book.
      outcome = (opportunity[:outcome_side] || :yes).to_s
      order = {
        ticker: opportunity[:ticker],
        action: opportunity[:side].to_s,
        side: outcome,
        :"#{outcome}_price" => opportunity[:price_cents],
        count: opportunity[:contracts],
        type: "limit",
        client_order_id: SecureRandom.uuid
      }

      return order.merge(mode: "dry_run") unless live?

      response = send_signed("POST", ORDERS_PATH, body: JSON.generate(order))
      order.merge(mode: "live", order_id: response.dig("order", "order_id"))
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
