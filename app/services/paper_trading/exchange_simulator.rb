# frozen_string_literal: true

module PaperTrading
  class ExchangeSimulator
    Order = Struct.new(:id, :symbol, :side, :price, :quantity, :status, :filled_qty, :created_at, :tp, :sl, :trailing, :hwm, keyword_init: true)

    attr_reader :orders, :fills, :equity_usd

    def initialize(starting_equity_usd: 10_000.0, maker_fee: 0.0005, slippage: 0.0002)
      @equity_usd = starting_equity_usd.to_f
      @orders = {}
      @fills = []
      @id_seq = 0
      @maker_fee = maker_fee
      @slippage = slippage
    end

    def place_limit(symbol:, side:, price:, quantity:, tp: nil, sl: nil, trailing: nil)
      id = next_id
      orders[id] = Order.new(id: id, symbol: symbol, side: side, price: price.to_f, quantity: quantity.to_f, status: :open, filled_qty: 0.0, created_at: Time.now.utc, tp: tp, sl: sl, trailing: trailing, hwm: nil)
      id
    end

    def cancel(id)
      o = orders[id]
      return unless o && o.status == :open
      o.status = :canceled
    end

    # Called per new 1h candle to simulate maker fills, trailing stop updates, and exits
    def on_candle(candle)
      # Try fills
      orders.values.select { |o| o.status == :open }.each do |o|
        bid = candle.close.to_f
        ask = candle.close.to_f
        case o.side
        when :buy
          if candle.low.to_f <= o.price.to_f
            fill_price = [ o.price.to_f, bid ].min
            apply_fill(o, fill_price)
          end
        when :sell
          if candle.high.to_f >= o.price.to_f
            fill_price = [ o.price.to_f, ask ].max
            apply_fill(o, fill_price)
          end
        end
      end

      # Update trailing stops and check exits
      orders.values.select { |o| o.status == :filled }.each do |o|
        update_trailing(o, candle)
        process_exits(o, candle)
      end
    end

    private

    def next_id
      @id_seq += 1
      @id_seq
    end

    def apply_fill(order, fill_price)
      order.status = :filled
      order.filled_qty = order.quantity
      order.hwm = fill_price # initialize high-watermark to fill for simplicity
      fee = fill_price * order.filled_qty * @maker_fee
      @equity_usd -= fee
      @fills << { order_id: order.id, side: order.side, price: fill_price, qty: order.filled_qty, fee: fee, time: Time.now.utc }
    end

    def update_trailing(order, candle)
      return unless order.trailing && order.side == :buy
      high = candle.high.to_f
      order.hwm = [ order.hwm.to_f, high ].max

      # Activate trailing after price passes activate_at
      return if order.trailing[:activate_at] && order.hwm < order.trailing[:activate_at]

      if order.trailing[:type] == :percent
        trail_pct = order.trailing[:pct].to_f
        new_sl = order.hwm * (1.0 - trail_pct)
        # Only move SL up, never down
        order.sl = [ order.sl.to_f, new_sl ].max
      end
    end

    def process_exits(order, candle)
      exit_price = nil
      if order.side == :buy
        if order.tp && candle.high.to_f >= order.tp.to_f
          exit_price = order.tp.to_f
        elsif order.sl && candle.low.to_f <= order.sl.to_f
          exit_price = order.sl.to_f
        end
      else
        if order.tp && candle.low.to_f <= order.tp.to_f
          exit_price = order.tp.to_f
        elsif order.sl && candle.high.to_f >= order.sl.to_f
          exit_price = order.sl.to_f
        end
      end
      return unless exit_price

      realize_pnl(order, exit_price)
      order.status = :closed
    end

    def realize_pnl(order, exit_price)
      entry_value = order.price.to_f * order.filled_qty
      exit_value = exit_price.to_f * order.filled_qty
      fee = exit_price.to_f * order.filled_qty * @maker_fee
      pnl = case order.side
            when :buy then exit_value - entry_value - fee
            when :sell then entry_value - exit_value - fee
            end
      @equity_usd += pnl
      @fills << { order_id: order.id, side: (order.side == :buy ? :sell : :buy), price: exit_price, qty: order.filled_qty, fee: fee, time: Time.now.utc }
    end
  end
end