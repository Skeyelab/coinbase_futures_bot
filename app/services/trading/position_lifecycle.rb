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
