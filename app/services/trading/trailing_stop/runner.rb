# frozen_string_literal: true

module Trading
  module TrailingStop
    class Runner
      DEFAULT_PROFIT_PERCENT = 0.4
      DEFAULT_TRAILING_PERCENT = 0.2
      DEFAULT_STOP_PERCENT = 0.3

      def initialize(logger: Rails.logger, positions_service: nil)
        @logger = logger
        @positions_service = positions_service || Trading::CoinbasePositions.new(logger: logger)
      end

      def enabled?
        ActiveModel::Type::Boolean.new.cast(ENV.fetch("TRAILING_STOP_ENABLED", "false"))
      end

      def close_triggered_positions(positions: Position.open)
        return {closed_count: 0, processed_ids: []} unless enabled?

        closed_count = 0
        processed_ids = []

        each_position(trailing_positions(positions)) do |position|
          trigger = evaluate_position(position)
          next if trigger == :hold

          if close_position(position, trigger)
            closed_count += 1
            processed_ids << position.id
          end
        rescue => e
          @logger.error("Trailing stop processing failed for position #{position.id}: #{e.message}")
        end

        {closed_count: closed_count, processed_ids: processed_ids}
      end

      def evaluate_position(position)
        current_price = position.get_current_market_price
        return :hold unless current_price

        algorithm = build_algorithm(position)
        signal = algorithm.tick(spot: current_price, sma: current_price)
        persist_state(position, algorithm, current_price, signal)
        signal
      end

      private

      attr_reader :logger, :positions_service

      def each_position(collection, &block)
        return collection.find_each(&block) if collection.respond_to?(:find_each)

        collection.each(&block)
      end

      def trailing_positions(positions)
        positions.where(trailing_stop_enabled: true, status: "OPEN")
      end

      def build_algorithm(position)
        state = normalized_state(position)

        calculator = Calculator.new(
          open_price: position.entry_price,
          profit_percent: state["profit_percent"] || DEFAULT_PROFIT_PERCENT,
          t_stop_percent: state["t_stop_percent"] || DEFAULT_TRAILING_PERCENT,
          stop_percent: state["stop_percent"] || inferred_stop_percent(position),
          direction: position.long? ? :long : :short,
          price_scale: trailing_price_scale
        )

        Algorithm.new(
          calculator: calculator,
          market_extreme: state["market_extreme"],
          profit_made: state["profit_made"],
          trailing_stop_price: state["trailing_stop_price"]
        )
      end

      def normalized_state(position)
        state = position.trailing_stop_state.presence || {}
        state.transform_keys(&:to_s)
      end

      def trailing_price_scale
        ENV.fetch("TRAILING_STOP_PRICE_SCALE", "5").to_i
      end

      def inferred_stop_percent(position)
        if position.stop_loss.present? && position.entry_price.to_f.positive?
          if position.long?
            ((position.entry_price.to_f - position.stop_loss.to_f) / position.entry_price.to_f * 100.0).abs
          else
            ((position.stop_loss.to_f - position.entry_price.to_f) / position.entry_price.to_f * 100.0).abs
          end
        else
          DEFAULT_STOP_PERCENT
        end
      end

      def persist_state(position, algorithm, current_price, signal)
        state = normalized_state(position).merge(
          algorithm.to_h.transform_keys(&:to_s)
        ).merge(
          "last_price" => current_price.to_f,
          "last_signal" => signal.to_s,
          "updated_at" => Time.current.iso8601,
          "profit_percent" => algorithm.calculator.profit_percent,
          "t_stop_percent" => algorithm.calculator.t_stop_percent,
          "stop_percent" => algorithm.calculator.stop_percent
        )

        position.update_columns(
          trailing_stop_state: state,
          stop_loss: algorithm.effective_stop_price,
          updated_at: Time.current
        )
      end

      def close_position(position, trigger)
        current_price = position.get_current_market_price || position.entry_price
        result = positions_service.close_position(product_id: position.product_id, size: position.size)

        if result["success"] || result["order_id"]
          position.force_close!(current_price, "Trailing stop #{trigger}")
          logger.info("Closed position #{position.id} via trailing stop (#{trigger})")
          true
        else
          logger.error("Trailing stop close failed for position #{position.id}: #{result.inspect}")
          false
        end
      rescue => e
        logger.error("Trailing stop close exception for position #{position.id}: #{e.message}")
        false
      end
    end
  end
end
