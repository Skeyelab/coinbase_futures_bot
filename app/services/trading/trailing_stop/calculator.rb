# frozen_string_literal: true

module Trading
  module TrailingStop
    class Calculator
      attr_reader :open_price, :profit_percent, :t_stop_percent, :stop_percent, :direction, :price_scale

      def initialize(open_price:, profit_percent:, t_stop_percent:, stop_percent:, direction: :long, price_scale: 5)
        @open_price = open_price.to_f
        @profit_percent = profit_percent.to_f
        @t_stop_percent = t_stop_percent.to_f
        @stop_percent = stop_percent.to_f
        @direction = direction.to_sym
        @price_scale = price_scale.to_i
      end

      def stop_price
        base = if long?
          open_price - percent_of(open_price, stop_percent)
        else
          open_price + percent_of(open_price, stop_percent)
        end
        round_down(base)
      end

      def profit_goal_price
        base = if long?
          open_price + percent_of(open_price, profit_percent)
        else
          open_price - percent_of(open_price, profit_percent)
        end
        round_down(base)
      end

      def initial_t_stop_price
        base = if long?
          profit_goal_price - percent_of(profit_goal_price, t_stop_percent)
        else
          profit_goal_price + percent_of(profit_goal_price, t_stop_percent)
        end
        round_down(base)
      end

      def t_stop_price_for(market_extreme)
        extreme = market_extreme.to_f
        base = if long?
          extreme - percent_of(extreme, t_stop_percent)
        else
          extreme + percent_of(extreme, t_stop_percent)
        end
        round_down(base)
      end

      def profit_goal_reached?(price)
        long? ? price.to_f >= profit_goal_price : price.to_f <= profit_goal_price
      end

      def stop_loss_triggered?(price, current_stop_price)
        long? ? current_stop_price.to_f >= price.to_f : current_stop_price.to_f <= price.to_f
      end

      private

      def long?
        direction == :long
      end

      def percent_of(amount, percent)
        amount.to_f * percent.to_f / 100.0
      end

      def round_down(value)
        factor = 10**price_scale
        (value.to_f * factor).floor / factor.to_f
      end
    end
  end
end
