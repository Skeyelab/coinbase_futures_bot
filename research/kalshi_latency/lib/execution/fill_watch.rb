# Watches one placed order until it fills or the clock runs out, then cancels
# whatever is left resting.
#
# This exists because gate item #3 is scored on REALIZED prices, and a placed
# order is not a fill. Without this, an order that rests forever is recorded as
# neither a fill nor a miss, and the fill-quality number quietly measures
# nothing.
module Execution
  class FillWatch
    DEFAULT_POLL_SECONDS = 2

    def initialize(client:, sleeper: ->(s) { sleep(s) }, now: -> { Time.now.to_f },
      poll_seconds: DEFAULT_POLL_SECONDS)
      @client = client
      @sleeper = sleeper
      @now = now
      @poll_seconds = poll_seconds
    end

    def settle(intent, timeout_seconds:)
      deadline = @now.call + timeout_seconds
      state = nil

      loop do
        # nil is "the venue cannot see it yet", not "no such order". Keeping
        # the last state we did see means a blip cannot erase what we learned.
        state = @client.order(intent[:order_id]) || state
        break if state && resting?(state).zero?
        break if @now.call >= deadline

        @sleeper.call(@poll_seconds)
      end

      # Never visible, but the order is real -- it was accepted. Cancel it and
      # say so, rather than reporting an unfilled order we never actually saw.
      if state.nil?
        @client.cancel(intent[:order_id])
        return {status: "unknown", filled: 0, realized_price_cents: nil,
                intended_price_cents: (intent[:price].to_f * 100).round(2), at_or_better: false}
      end

      @client.cancel(intent[:order_id]) if resting?(state).positive?
      report(intent, state)
    end

    private

    def resting?(state)
      state["remaining_count_fp"].to_f
    end

    # Three outcomes, not two. A partial that scores as a fill inflates gate
    # item #3 with orders that mostly did not happen.
    def status_for(filled, remaining)
      return "unfilled" if filled.zero?

      remaining.positive? ? "partial" : "filled"
    end

    def report(intent, state)
      filled = state["fill_count_fp"].to_f
      cost = state["taker_fill_cost_dollars"].to_f + state["maker_fill_cost_dollars"].to_f
      # Nothing filled means there is no price to report. Dividing anyway gives
      # NaN, and NaN compares false against every threshold without saying why.
      realized = filled.zero? ? nil : (cost / filled * 100).round(2)
      # v2 carries one price, a fixed-point dollar STRING. The rest of this
      # project reasons in cents, so the boundary converts once, here.
      intended = (intent[:price].to_f * 100).round(2)

      {status: status_for(filled, resting?(state)), filled: filled.floor,
       realized_price_cents: realized, intended_price_cents: intended,
       at_or_better: !realized.nil? && at_or_better?(intent, realized, intended)}
    end

    # A buy is better cheaper; a sell is better dearer. Comparing them the same
    # way scores every sell backwards.
    def at_or_better?(intent, realized, intended)
      (intent[:action] == "buy") ? realized <= intended : realized >= intended
    end
  end
end
