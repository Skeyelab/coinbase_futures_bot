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

    def close(position, reason:)
      current_price = resolve_price(position)
      return Result.new(success: false, close_price: nil, reason: reason, fallback: false) unless current_price

      api_result = attempt_api_close(position)

      if api_success?(api_result)
        position.force_close!(current_price, reason)
        @logger.info("Closed position #{position.id} via API at #{current_price}: #{reason}")
        # Protections layer (issue #397, ADR 0003): starting a cooldown here — the
        # single funnel every day/swing/dollar/trailing exit passes through —
        # blocks immediate re-entry on the symbol just exited.
        Trading::Protections::CooldownPeriod.record_exit(symbol: position.product_id)
        # StoplossGuard (issue #400): a losing close may trip the guard and halt
        # the offending side after a cluster of losses.
        evaluate_stoploss_guard(position)
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

    def attempt_api_close(position)
      @positions_service.close_position(
        product_id: position.product_id,
        size: position.size
      )
    rescue => e
      @logger.error("API close raised for position #{position.id}: #{e.message}")
      nil
    end

    def api_success?(result)
      result && (result["success"] || result["order_id"] || result[:success])
    end

    def resolve_price(position)
      RecentMarketPrice.for_product(position.product_id) || begin
        @logger.warn("No recent price for #{position.product_id}, using entry price")
        position.entry_price
      end
    end
  end
end
