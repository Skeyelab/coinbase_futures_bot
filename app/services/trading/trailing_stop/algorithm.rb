# frozen_string_literal: true

module Trading
  module TrailingStop
    class Algorithm
      attr_reader :calculator, :market_extreme, :profit_made, :trailing_stop_price

      def initialize(calculator:, market_extreme: nil, profit_made: false, trailing_stop_price: nil)
        @calculator = calculator
        @market_extreme = market_extreme || default_market_extreme
        @profit_made = !!profit_made
        @trailing_stop_price = trailing_stop_price || calculator.initial_t_stop_price
      end

      def tick(spot:, sma:)
        current_price = sma.to_f
        effective_stop = effective_stop_price
        trailing_active = profit_made

        if calculator.stop_loss_triggered?(current_price, effective_stop)
          trailing_active ? :trailing_stop : :stop_loss
        else
          unlock_profit(current_price)
          update_market_extreme(spot.to_f)
          :hold
        end
      end

      def effective_stop_price
        profit_made ? trailing_stop_price : calculator.stop_price
      end

      def to_h
        {
          market_extreme: market_extreme,
          profit_made: profit_made,
          trailing_stop_price: trailing_stop_price
        }
      end

      private

      def long?
        calculator.direction == :long
      end

      def default_market_extreme
        long? ? 0.0 : Float::INFINITY
      end

      def update_market_extreme(spot)
        if long?
          return unless spot > market_extreme
        else
          return unless spot < market_extreme
        end

        @market_extreme = spot
        @trailing_stop_price = calculator.t_stop_price_for(spot)
      end

      def unlock_profit(price)
        @profit_made ||= calculator.profit_goal_reached?(price)
      end
    end
  end
end
