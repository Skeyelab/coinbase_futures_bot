# frozen_string_literal: true

module Trading
  class PositionLifecycle
    Result = Struct.new(:success, :close_price, :reason, :fallback, keyword_init: true) do
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
        Result.new(success: true, close_price: current_price, reason: reason, fallback: false)
      else
        @logger.warn("API close failed for position #{position.id}, using local fallback")
        position.force_close!(current_price, reason)
        Result.new(success: true, close_price: current_price, reason: reason, fallback: true)
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
