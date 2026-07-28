# frozen_string_literal: true

module Trading
  module ExecutionCalibration
    # Where a Fill's numbers come from. Two sources, one interface, because the
    # dry-run rehearsal and the live run must exercise the SAME runner code —
    # a rehearsal that runs a different path proves nothing about the run.
    module FillObserver
      # Live: Coinbase's own fills are the only ground truth for a commission
      # and for whether a post-only order rested or crossed. Polls because a
      # maker order may fill some time after it is accepted — or never, which is
      # the observation #486 is buying.
      class Venue
        def initialize(positions_service:, multiplier:, logger: Rails.logger, sleeper: ->(s) { sleep(s) })
          @positions_service = positions_service
          @multiplier = multiplier
          @logger = logger
          @sleeper = sleeper
        end

        def observe(phase:, side:, intended_price:, order_result:, deadline:, poll_seconds: 2)
          order_id = extract_order_id(order_result)
          return nil if order_id.blank?

          loop do
            raw = find_fill(order_id)
            return build(raw, phase: phase, side: side, intended_price: intended_price, order_id: order_id) if raw
            return nil if Time.current >= deadline

            @sleeper.call(poll_seconds)
          end
        end

        private

        def find_fill(order_id)
          @positions_service.list_fills(limit: 50).find { |f| f["order_id"].to_s == order_id.to_s }
        rescue => e
          @logger.warn("[ExecutionCalibration] fills lookup failed: #{e.class}: #{e.message}")
          nil
        end

        def build(raw, phase:, side:, intended_price:, order_id:)
          Fill.new(
            phase: phase, side: side, order_id: order_id,
            liquidity: (raw["liquidity_indicator"].presence || "TAKER").to_s.upcase,
            intended_price: intended_price.to_f,
            fill_price: raw["price"].to_f,
            commission: raw["commission"].to_f,
            contracts: raw["size"].to_f,
            contract_multiplier: @multiplier,
            filled_at: raw["trade_time"]
          )
        end

        def extract_order_id(result)
          return nil unless result.is_a?(Hash)

          result["order_id"] || result.dig("success_response", "order_id")
        end
      end

      # Dry-run: the paper simulator already returns the fill price and the
      # modeled fee from Trading::CoinbasePositions#simulate_order. It always
      # fills, so a dry-run rehearsal exercises the mechanics and CANNOT measure
      # a maker fill rate — the report says so rather than reporting 100%.
      class Simulated
        def initialize(multiplier:)
          @multiplier = multiplier
        end

        def observe(phase:, side:, intended_price:, order_result:, deadline:, poll_seconds: nil)
          return nil unless order_result.is_a?(Hash)
          return nil if order_result["success"].blank? && order_result["order_id"].blank?

          Fill.new(
            phase: phase, side: side,
            order_id: order_result["order_id"],
            liquidity: order_result["liquidity"].presence || "TAKER",
            intended_price: intended_price.to_f,
            fill_price: (order_result["price"] || intended_price).to_f,
            commission: order_result["fee"].to_f,
            contracts: 1.0,
            contract_multiplier: @multiplier,
            filled_at: Time.current
          )
        end
      end
    end
  end
end
