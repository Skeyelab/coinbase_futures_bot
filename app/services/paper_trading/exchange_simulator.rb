# frozen_string_literal: true

module PaperTrading
  class ExchangeSimulator
    Order = Struct.new(:id, :symbol, :side, :price, :quantity, :status, :filled_qty, :created_at, :tp, :sl,
      :entry_fill, :entry_time, :funding_cost)

    attr_reader :orders, :fills, :equity_usd

    # fee_rate is the canonical per-side fee; maker_fee is kept as a legacy
    # alias. Slippage is applied adversely to every fill (issue #353: entries
    # from momentum signals cross the spread, so fills are taker-priced).
    #
    # Funding (issue #391) is OFF unless both funding_interval_seconds and a
    # positive funding_rate_per_interval are supplied. When active it is a
    # constant *adverse* charge (a cost to either side) applied at position
    # close for every funding timestamp the hold crossed; this is the
    # sensitivity knob ADR 0002 specifies "until history accrues". Active
    # funding reads candle.timestamp, so callers must pass timestamped candles.
    def initialize(starting_equity_usd: 10_000.0, maker_fee: nil, fee_rate: nil, slippage: 0.0002,
      funding_interval_seconds: nil, funding_rate_per_interval: nil)
      @equity_usd = starting_equity_usd.to_f
      @orders = {}
      @fills = []
      @id_seq = 0
      @fee_rate = (fee_rate || maker_fee || 0.0005).to_f
      @slippage = slippage.to_f
      @funding_interval_seconds = funding_interval_seconds.to_i
      @funding_rate_per_interval = funding_rate_per_interval.to_f
      @funding_active = @funding_interval_seconds.positive? && @funding_rate_per_interval.positive?
    end

    def place_limit(symbol:, side:, price:, quantity:, tp: nil, sl: nil)
      id = next_id
      orders[id] =
        Order.new(id: id, symbol: symbol, side: side, price: price.to_f, quantity: quantity.to_f, status: :open,
          filled_qty: 0.0, created_at: Time.now.utc, tp: tp, sl: sl)
      id
    end

    def cancel(id)
      o = orders[id]
      return unless o && o.status == :open

      o.status = :canceled
    end

    # Called per new 1h candle to simulate maker fills at bid/ask
    def on_candle(candle)
      orders.values.select { |o| o.status == :open }.each do |o|
        bid = candle.close.to_f # simplification; assume close ~ bid
        ask = candle.close.to_f # simplification; assume close ~ ask
        case o.side
        when :buy
          if candle.low.to_f <= o.price.to_f
            fill_price = [o.price.to_f, bid].min
            apply_fill(o, fill_price, candle)
          end
        when :sell
          if candle.high.to_f >= o.price.to_f
            fill_price = [o.price.to_f, ask].max
            apply_fill(o, fill_price, candle)
          end
        end
      end

      # Manage exits for filled orders (simple TP/SL checks on candle extremes)
      orders.values.select { |o| o.status == :filled && (o.tp || o.sl) }.each do |o|
        exit_price = nil
        if o.side == :buy
          if o.tp && candle.high.to_f >= o.tp.to_f
            exit_price = o.tp.to_f
          elsif o.sl && candle.low.to_f <= o.sl.to_f
            exit_price = o.sl.to_f
          end
        elsif o.tp && candle.low.to_f <= o.tp.to_f
          exit_price = o.tp.to_f
        elsif o.sl && candle.high.to_f >= o.sl.to_f
          exit_price = o.sl.to_f
        end
        next unless exit_price

        realize_pnl(o, exit_price, candle)
        o.status = :closed
      end
    end

    private

    def next_id
      @id_seq += 1
      @id_seq
    end

    def apply_fill(order, fill_price, candle)
      slipped = slip(fill_price, order.side)
      order.status = :filled
      order.filled_qty = order.quantity
      order.entry_fill = slipped
      order.funding_cost = 0.0
      order.entry_time = candle.timestamp if @funding_active
      fee = slipped * order.filled_qty * @fee_rate
      @equity_usd -= fee
      @fills << {order_id: order.id, side: order.side, price: slipped, qty: order.filled_qty, fee: fee,
                  time: Time.now.utc}
    end

    def realize_pnl(order, exit_price, candle)
      exit_side = (order.side == :buy) ? :sell : :buy
      slipped_exit = slip(exit_price.to_f, exit_side)
      entry_price = (order.entry_fill || order.price).to_f
      entry_value = entry_price * order.filled_qty
      exit_value = slipped_exit * order.filled_qty
      fee = slipped_exit * order.filled_qty * @fee_rate
      pnl = case order.side
      when :buy then exit_value - entry_value - fee
      when :sell then entry_value - exit_value - fee
      end
      @equity_usd += pnl
      @equity_usd -= charge_funding(order, candle, entry_value)
      @fills << {order_id: order.id, side: exit_side, price: slipped_exit,
                  qty: order.filled_qty, fee: fee, time: Time.now.utc}
    end

    # Constant *adverse* funding: a cost to either side for each funding
    # timestamp the hold crossed (issue #391). Charged on entry notional at
    # position close. Returns the dollars charged (0.0 when funding is off).
    def charge_funding(order, candle, entry_notional)
      return 0.0 unless @funding_active

      intervals = CostModel.funding_intervals_crossed(
        entry_time: order.entry_time, exit_time: candle.timestamp,
        interval: @funding_interval_seconds
      )
      funding = intervals * @funding_rate_per_interval * entry_notional
      order.funding_cost = funding
      funding
    end

    # Adverse slippage: buys fill higher, sells fill lower.
    def slip(price, side)
      (side == :buy) ? price * (1 + @slippage) : price * (1 - @slippage)
    end
  end
end
