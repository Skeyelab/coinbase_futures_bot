# frozen_string_literal: true

module Backtest
  # Event-driven backtester (issue #298): replays real candle history in time
  # order, drives the LIVE strategy (MultiTimeframeSignal via the shared
  # Signals::Indicators) at each step, and simulates fills, TP/SL exits, fees,
  # and slippage with PaperTrading::ExchangeSimulator — never with random
  # exits.
  #
  # Costs default to TAKER pricing (issue #353): momentum entries cross the
  # spread. The default rate is the ~3 bps US-perp taker fee (ADR 0002 / issue
  # #391); override via BACKTEST_TAKER_FEE_RATE or fee_rate: to match the current
  # fee schedule.
  class Engine
    STEP_SCOPES = {
      "1m" => :one_minute,
      "5m" => :five_minute,
      "15m" => :fifteen_minute,
      "1h" => :hourly
    }.freeze

    attr_reader :strategy

    def initialize(symbol:, strategy: nil, step: "5m", starting_equity: 10_000.0,
      fee_rate: nil, slippage: 0.0002, contract_size_usd: nil, protection_cooldown_seconds: nil,
      funding_bps_per_interval: nil, funding_interval_seconds: nil,
      min_roi_schedule: nil, liquidation_buffer: nil, stoploss_guard: nil, max_drawdown: nil,
      logger: Rails.logger)
      @symbol = symbol
      @strategy = strategy || Trading::StrategyFactory.multi_timeframe(resolve_symbols: false)
      @step_scope = STEP_SCOPES.fetch(step) { raise ArgumentError, "unknown step #{step.inspect}" }
      @starting_equity = starting_equity.to_f
      @fee_rate = (fee_rate || CostModel.taker_fee_rate).to_f
      @slippage = slippage.to_f
      # Perp funding (issue #391): a constant *adverse* sensitivity knob, ON by
      # default so backtests stop silently pricing funding as free (ADR 0002).
      # Default 2 bps/interval, hourly; set funding_bps_per_interval: 0 to disable.
      funding_bps = (funding_bps_per_interval || ENV["BACKTEST_FUNDING_BPS_PER_INTERVAL"] || 2.0).to_f
      @funding_rate_per_interval = (funding_bps > 0) ? funding_bps / 10_000.0 : nil
      @funding_interval_seconds =
        (funding_interval_seconds || ENV["BACKTEST_FUNDING_INTERVAL_SECONDS"] || 3600).to_i
      # Protections (issue #397, ADR 0003) are evaluated inside the backtest on the
      # simulated clock against a run-local in-memory store, so backtest metrics
      # reflect the same cooldown/guard behavior as live without touching live state.
      @protection_cooldown_seconds =
        protection_cooldown_seconds || Trading::Protections::CooldownPeriod.default_cooldown_seconds
      # Signals size in CONTRACTS; the simulator prices in base units. Convert
      # via the strategy's own $-per-contract model or the PnL/fees are
      # inflated ~(price / contract_size_usd)x — ~1000x for BTC.
      @contract_size_usd = (contract_size_usd || strategy_contract_size_usd || 100.0).to_f
      # Min-ROI time-decay exit (issue #398), evaluated per candle on the simulated
      # clock so backtest exit mix reflects live behavior. Explicit schedule for
      # tests; otherwise resolved from config (inert by default).
      @min_roi = min_roi_schedule ? Trading::MinimumRoiExit.new(min_roi_schedule)
        : Trading::MinimumRoiExit.from_config(symbol: @symbol)
      # Liquidation buffer (issue #399): highest-precedence safety exit, evaluated
      # per candle against the candle's extreme so the backtest closes before the
      # exchange would liquidate. Explicit for tests; else from config.
      @liq_buffer = liquidation_buffer || Trading::LiquidationBuffer.from_config(symbol: @symbol)
      # StoplossGuard (issue #400): fed the run's losing exits on the simulated
      # clock; its locks land in the run-local store the entry check consults, so
      # a loss cluster halts entries identically to live.
      @stoploss_guard = stoploss_guard || Trading::Protections::StoplossGuard.from_config(symbol: @symbol)
      # MaxDrawdown (issue #401): global equity-drawdown halt, evaluated per candle
      # against the run's equity curve on the simulated clock.
      @max_drawdown = max_drawdown || Trading::Protections::MaxDrawdown.from_config
      @logger = logger
    end

    def run(from:, to:)
      sim = PaperTrading::ExchangeSimulator.new(starting_equity_usd: @starting_equity,
        fee_rate: @fee_rate, slippage: @slippage,
        funding_interval_seconds: @funding_interval_seconds,
        funding_rate_per_interval: @funding_rate_per_interval)
      equity_curve = [@starting_equity]
      entered_at = {}
      exited_at = {}
      protection_store = Trading::ProtectionLock::MemoryStore.new
      losing_exits = []
      halts = []
      equity_points = [{at: from, equity: @starting_equity}]

      step_candles(from, to).each do |candle|
        maybe_enter(sim, candle, entered_at, protection_store)
        # Liquidation buffer takes precedence over the sim's TP/SL pass — a candle
        # that would liquidate closes at the buffered price first.
        maybe_liquidation_exit(sim, candle)
        sim.on_candle(candle)
        maybe_min_roi_exit(sim, candle, entered_at)
        stamp_exits(sim, candle, exited_at, protection_store, losing_exits, halts)
        equity_curve << sim.equity_usd
        equity_points << {at: candle.timestamp, equity: sim.equity_usd}
        maybe_max_drawdown_halt(candle, equity_points, protection_store, halts)
      end

      Result.new(trades: build_trades(sim, entered_at, exited_at),
        equity_curve: equity_curve, starting_equity: @starting_equity, from: from, to: to,
        protection_halts: halts)
    end

    private

    def step_candles(from, to)
      Candle.for_symbol(@symbol).public_send(@step_scope)
        .where(timestamp: from..to).order(:timestamp)
    end

    # One position at a time: only ask the strategy while flat.
    def maybe_enter(sim, candle, entered_at, protection_store)
      return if position_active?(sim)

      sig = @strategy.signal(symbol: @symbol, equity_usd: sim.equity_usd, as_of: candle.timestamp)
      return unless sig && sig[:quantity].to_f > 0

      # Protections parity: a symbol/side under an active lock produces no entry,
      # evaluated on the simulated clock against the run-local store.
      return if Trading::Protections.blocked?(symbol: @symbol, side: sig[:side].to_s,
        now: candle.timestamp, store: protection_store)

      base_qty = contracts_to_base_units(sig[:quantity], sig[:price])
      return unless base_qty > 0

      id = sim.place_limit(symbol: @symbol, side: SideNormalizer.simulator_fill_side(sig[:side]),
        price: sig[:price], quantity: base_qty, tp: sig[:tp], sl: sig[:sl])
      entered_at[id] = candle.timestamp
    end

    # contracts x ($ notional per contract) / price = base units
    def contracts_to_base_units(contracts, price)
      return 0.0 unless price.to_f.positive?

      contracts.to_f * @contract_size_usd / price.to_f
    end

    def strategy_contract_size_usd
      config = @strategy.instance_variable_get(:@config)
      config.is_a?(Hash) ? config[:contract_size_usd] : nil
    end

    def position_active?(sim)
      sim.orders.values.any? do |o|
        o.status == :open || (o.status == :filled && (o.tp || o.sl))
      end
    end

    # Liquidation-buffer exit (issue #399): if the candle's extreme reaches the
    # buffered pre-liquidation price for the open position, force-close there —
    # before the sim's TP/SL pass. Uses candle low for longs, high for shorts.
    def maybe_liquidation_exit(sim, candle)
      return unless @liq_buffer.enabled?

      sim.orders.values.each do |o|
        next unless o.status == :filled

        entry = (o.entry_fill || o.price).to_f
        side = (o.side == :buy) ? "long" : "short"
        extreme = (o.side == :buy) ? candle.low.to_f : candle.high.to_f

        next unless @liq_buffer.breached?(entry_price: entry, side: side, current_price: extreme)

        exit_price = @liq_buffer.buffered_exit_price(entry_price: entry, side: side)
        sim.force_close(o.id, price: exit_price, reason: :liquidation_buffer, candle: candle)
      end
    end

    # Min-ROI time-decay exit (issue #398): after the simulator's TP/SL pass, if a
    # position is still open, force-close it at the candle close when its
    # age-decayed profit bar is met. Uses the simulated clock (candle.timestamp -
    # entered_at) for minutes_held. Only an earlier take-profit — never a stop.
    def maybe_min_roi_exit(sim, candle, entered_at)
      return unless @min_roi.enabled?

      sim.orders.values.each do |o|
        next unless o.status == :filled

        entry = (o.entry_fill || o.price).to_f
        next unless entry.positive?

        move = (candle.close.to_f - entry) / entry
        profit_ratio = (o.side == :buy) ? move : -move
        minutes_held = ((candle.timestamp - entered_at[o.id]) / 60.0)

        next unless @min_roi.exit_reason(profit_ratio: profit_ratio, minutes_held: minutes_held)

        sim.force_close(o.id, price: candle.close.to_f, reason: :time_decay_roi, candle: candle)
      end
    end

    # MaxDrawdown parity (issue #401): peak equity within the guard's lookback vs
    # current, evaluated on the simulated clock. A breach writes a global lock the
    # entry check consults and is recorded for attribution.
    def maybe_max_drawdown_halt(candle, equity_points, protection_store, halts)
      return unless @max_drawdown.enabled?

      window_start = candle.timestamp - @max_drawdown.lookback_seconds
      peak = equity_points.select { |p| p[:at] >= window_start }.map { |p| p[:equity] }.max
      current = equity_points.last[:equity]

      new_locks = @max_drawdown.evaluate(peak: peak, current: current,
        now: candle.timestamp, store: protection_store)
      new_locks.each do |lock|
        halts << {source: lock["source"], symbol: nil, side: "both", at: candle.timestamp}
      end
    end

    def stamp_exits(sim, candle, exited_at, protection_store, losing_exits, halts)
      fills_by_order = sim.fills.group_by { |f| f[:order_id] }

      sim.orders.values.each do |o|
        next unless o.status == :closed
        next if exited_at.key?(o.id) # already stamped; only act on the new exit

        exited_at[o.id] = candle.timestamp
        # Protections parity: a completed exit starts a cooldown on the simulated
        # clock, mirroring PositionLifecycle#close in live trading.
        Trading::Protections::CooldownPeriod.record_exit(symbol: @symbol,
          cooldown_seconds: @protection_cooldown_seconds, now: candle.timestamp,
          store: protection_store)

        # StoplossGuard parity: feed losing exits to the guard on the simulated
        # clock; new locks (a halt) are recorded for attribution.
        next unless realized_pnl(fills_by_order[o.id], o.side).negative?

        losing_exits << {side: (o.side == :buy) ? "long" : "short", at: candle.timestamp}
        new_locks = @stoploss_guard.evaluate(symbol: @symbol, exits: losing_exits,
          now: candle.timestamp, store: protection_store)
        new_locks.each do |lock|
          halts << {source: lock["source"], symbol: lock["symbol"], side: lock["side"], at: candle.timestamp}
        end
      end
    end

    # Realized PnL for a closed order from its entry/exit fills (fees included).
    def realized_pnl(fills, side)
      entry, exit_fill = fills
      return 0.0 unless entry && exit_fill

      direction = (side == :buy) ? 1 : -1
      gross = (exit_fill[:price] - entry[:price]) * entry[:qty] * direction
      gross - entry[:fee] - exit_fill[:fee]
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
        funding = order.funding_cost.to_f
        {
          side: (order.side == :buy) ? :long : :short,
          entry_price: entry[:price],
          exit_price: exit_fill[:price],
          quantity: entry[:qty],
          pnl: gross - fees - funding,
          fees: fees,
          funding: funding,
          entered_at: entered_at[order.id],
          exited_at: exited_at[order.id],
          # nil exit_reason = closed by the simulator's fixed TP/SL pass.
          exit_reason: order.exit_reason || :fixed_tp_sl
        }
      end
    end
  end
end
