# frozen_string_literal: true

module Trading
  class PositionLifecycle
    Result = Struct.new(:success, :close_price, :reason, :fallback) do
      def success? = success
    end

    def initialize(positions_service:, logger: Rails.logger)
      @positions_service = positions_service
      @logger = logger
    end

    # `size` nil (or >= the tracked size) closes the whole position. A smaller
    # size is a PARTIAL reduce: the closed contracts are realized and the
    # position stays OPEN with the remainder. Both are exits as far as the
    # protections layer is concerned — a partial realizes real P&L, so it must
    # feed the cooldown, the stoploss guard and the daily loss caps exactly like
    # a full close. Routing both through one method is what keeps that true:
    # every caller that can reduce a position gets the protections for free.
    def close(position, reason:, size: nil)
      current_price = resolve_price(position)
      return Result.new(success: false, close_price: nil, reason: reason, fallback: false) unless current_price

      partial_size = resolve_partial_size(position, size)
      if partial_size == :invalid
        @logger.error("Refusing to close position #{position.id}: non-positive size #{size.inspect}")
        return Result.new(success: false, close_price: nil, reason: reason, fallback: false)
      end

      api_result = attempt_api_close(position, partial_size)

      if api_success?(api_result)
        # The record whose realized P&L this exit produced: the position itself
        # on a full close, the split-off CLOSED portion on a partial.
        realized = if partial_size
          position.close_partial!(partial_size, current_price, reason, exit_fee: close_fee(api_result))
        else
          position.force_close!(current_price, reason)
          position
        end

        unless realized
          @logger.error("Position #{position.id} could not realize a #{partial_size} close after a filled API close")
          return Result.new(success: false, close_price: nil, reason: reason, fallback: false)
        end

        portion = partial_size ? "#{partial_size} of " : nil
        @logger.info("Closed #{portion}position #{position.id} via API at #{current_price}: #{reason}")
        # Protections layer (issue #397, ADR 0003): starting a cooldown here — the
        # single funnel every day/swing/dollar/trailing exit passes through —
        # blocks immediate re-entry on the symbol just exited.
        Trading::Protections::CooldownPeriod.record_exit(symbol: position.product_id)
        # StoplossGuard (issue #400): a losing close may trip the guard and halt
        # the offending side after a cluster of losses.
        evaluate_stoploss_guard(realized)
        # Loss caps (issue #482, #392 condition 3): evaluated here because this
        # is the moment a loss becomes REALIZED, so the cap trips on the trade
        # that breached it rather than whenever a periodic job next happens to
        # run. Never allowed to fail the close — the position is already flat
        # and raising here would misreport a successful exit.
        begin
          Trading::LossLimits.evaluate!(logger: @logger)
        rescue => e
          @logger.error("[PositionLifecycle] loss-limit evaluation failed: #{e.class}: #{e.message}")
        end
        Result.new(success: true, close_price: current_price, reason: reason, fallback: false)
      else
        # Do NOT mark the DB position CLOSED here. The exchange close failed, so
        # real exposure likely remains; faking success created a "phantom-flat"
        # position the bot believed it was out of. Fail loud and leave it OPEN so
        # the caller retries/alerts instead of trading blind.
        @logger.error("API close failed for position #{position.id}; leaving OPEN to avoid phantom-flat: #{reason}")
        Result.new(success: false, close_price: nil, reason: reason, fallback: false)
      end
    end

    private

    # After a LOSING close, feed the guard the recent losing closes for this
    # symbol and let it decide whether the cluster warrants a halt. Only the
    # symbol's own losses are queried (matches the default per-symbol scope); a
    # global-scope live query across all symbols is a follow-up. On a fresh halt,
    # a Slack warning goes out — a StoplossGuard trip is genuinely notable.
    def evaluate_stoploss_guard(position)
      return unless position.pnl&.negative?

      guard = Trading::Protections::StoplossGuard.from_config(symbol: position.product_id)
      return unless guard.enabled?

      exits = Position.closed.by_product(position.product_id)
        .where("close_time >= ?", 24.hours.ago).where("pnl < 0")
        .map { |p| {side: p.side.to_s.downcase, at: p.close_time} }

      locks = guard.evaluate(symbol: position.product_id, exits: exits)
      return if locks.empty?

      locks.each do |lock|
        @logger.warn("[StoplossGuard] halted #{lock["symbol"] || "ALL"} #{lock["side"]}: #{lock["reason"]}")
        SlackNotificationService.alert("warning", "StoplossGuard halt",
          "Halted #{lock["symbol"] || "all symbols"} (#{lock["side"]}) — #{lock["reason"]}.")
      end
    end

    # nil       -> full close
    # BigDecimal-> partial reduce of that many contracts
    # :invalid  -> a size was asked for that cannot be closed
    def resolve_partial_size(position, size)
      return nil if size.nil? || size.to_s.strip.empty?

      requested = BigDecimal(size.to_s)
      return :invalid unless requested.positive?
      return nil if requested >= position.size

      requested
    rescue ArgumentError
      :invalid
    end

    # `position:` tells the service two things: close THIS row (not whatever
    # `by_product(...).order(:entry_time).last` happens to return, which is a
    # different row whenever several are open on the product), and leave
    # realizing it to us. We are the single writer of realized P&L here — we
    # hold the exit reason and we must run the protections layer on the row that
    # results. A service that also closed it would double-realize a reduce.
    def attempt_api_close(position, partial_size = nil)
      @positions_service.close_position(
        product_id: position.product_id,
        size: partial_size || position.size,
        position: position
      )
    rescue => e
      @logger.error("API close raised for position #{position.id}: #{e.message}")
      nil
    end

    # The fee the venue (or the paper simulator) charged for THIS close, taken
    # from the order result we already have. Both paths report it under "fee";
    # see Trading::CoinbasePositions#simulate_order and the entry_fee/exit_fee
    # writes in its local-record methods. nil when the result carries no fee —
    # unknown cost, not free cost.
    def close_fee(api_result)
      return nil unless api_result.is_a?(Hash)

      api_result["fee"] || api_result[:fee]
    end

    def api_success?(result)
      result && (result["success"] || result["order_id"] || result[:success])
    end

    def resolve_price(position)
      RecentMarketPrice.mark(position, logger: @logger).price
    end
  end
end
