# frozen_string_literal: true

module Backtest
  # Event-driven backtester (issue #298): replays real candle history in time
  # order, drives the LIVE strategy (MultiTimeframeSignal via the shared
  # Signals::Indicators) at each step, and simulates fills, TP/SL exits, fees,
  # and slippage with PaperTrading::ExchangeSimulator — never with random
  # exits.
  #
  # Costs default to TAKER pricing (issue #353): momentum entries cross the
  # spread. The default rate approximates Coinbase CDE taker fees
  # (~$0.15/side per $100-notional contract = 15 bps); override via
  # BACKTEST_TAKER_FEE_RATE or fee_rate: to match the current fee schedule.
  class Engine
    STEP_SCOPES = {
      "1m" => :one_minute,
      "5m" => :five_minute,
      "15m" => :fifteen_minute,
      "1h" => :hourly
    }.freeze

    attr_reader :strategy

    def initialize(symbol:, strategy: nil, step: "5m", starting_equity: 10_000.0,
      fee_rate: nil, slippage: 0.0002, logger: Rails.logger)
      @symbol = symbol
      @strategy = strategy || Strategy::MultiTimeframeSignal.new(resolve_symbols: false)
      @step_scope = STEP_SCOPES.fetch(step) { raise ArgumentError, "unknown step #{step.inspect}" }
      @starting_equity = starting_equity.to_f
      @fee_rate = (fee_rate || CostModel.taker_fee_rate).to_f
      @slippage = slippage.to_f
      @logger = logger
    end

    def run(from:, to:)
      sim = PaperTrading::ExchangeSimulator.new(starting_equity_usd: @starting_equity,
        fee_rate: @fee_rate, slippage: @slippage)
      equity_curve = [@starting_equity]
      entered_at = {}
      exited_at = {}

      step_candles(from, to).each do |candle|
        maybe_enter(sim, candle, entered_at)
        sim.on_candle(candle)
        stamp_exits(sim, candle, exited_at)
        equity_curve << sim.equity_usd
      end

      Result.new(trades: build_trades(sim, entered_at, exited_at),
        equity_curve: equity_curve, starting_equity: @starting_equity, from: from, to: to)
    end

    private

    def step_candles(from, to)
      Candle.for_symbol(@symbol).public_send(@step_scope)
        .where(timestamp: from..to).order(:timestamp)
    end

    # One position at a time: only ask the strategy while flat.
    def maybe_enter(sim, candle, entered_at)
      return if position_active?(sim)

      sig = @strategy.signal(symbol: @symbol, equity_usd: sim.equity_usd, as_of: candle.timestamp)
      return unless sig && sig[:quantity].to_f > 0

      id = sim.place_limit(symbol: @symbol, side: SideNormalizer.simulator_fill_side(sig[:side]),
        price: sig[:price], quantity: sig[:quantity], tp: sig[:tp], sl: sig[:sl])
      entered_at[id] = candle.timestamp
    end

    def position_active?(sim)
      sim.orders.values.any? do |o|
        o.status == :open || (o.status == :filled && (o.tp || o.sl))
      end
    end

    def stamp_exits(sim, candle, exited_at)
      sim.orders.values.each do |o|
        exited_at[o.id] ||= candle.timestamp if o.status == :closed
      end
    end

    # Pair entry/exit fills per order into round-trip trade records. Trades
    # still open at the end of the replay are excluded from metrics.
    def build_trades(sim, entered_at, exited_at)
      fills_by_order = sim.fills.group_by { |f| f[:order_id] }

      sim.orders.values.select { |o| o.status == :closed }.filter_map do |order|
        entry, exit_fill = fills_by_order[order.id]
        next unless entry && exit_fill

        direction = (order.side == :buy) ? 1 : -1
        gross = (exit_fill[:price] - entry[:price]) * entry[:qty] * direction
        fees = entry[:fee] + exit_fill[:fee]
        {
          side: (order.side == :buy) ? :long : :short,
          entry_price: entry[:price],
          exit_price: exit_fill[:price],
          quantity: entry[:qty],
          pnl: gross - fees,
          fees: fees,
          entered_at: entered_at[order.id],
          exited_at: exited_at[order.id]
        }
      end
    end
  end
end
