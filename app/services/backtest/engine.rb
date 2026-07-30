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

    # A run is only interpretable alongside the assumptions it ran under, and
    # several of these are RESOLVED here rather than passed in (fee_rate falls
    # back to CostModel, contract_size_usd to the strategy's own model). Exposed
    # so BacktestRun can record what was actually used (issue #406).
    attr_reader :symbol, :step, :starting_equity, :fee_rate, :slippage, :contract_size_usd, :per_contract_fee, :min_confidence

    # Last-resort funding rate when a product has no observed rows at all. Inert
    # in practice: CostModel.perp? treats "no funding history" as "not a perp",
    # so the rate is nulled before use. Kept as the historical value so the
    # behaviour of an unobserved product is unchanged.
    DEFAULT_FUNDING_BPS_PER_INTERVAL = 2.0

    def initialize(symbol:, strategy: nil, step: "5m", starting_equity: 10_000.0,
      fee_rate: nil, per_contract_fee: nil, slippage: 0.0002, contract_size_usd: nil, protection_cooldown_seconds: nil,
      preload_candles: true, fill_model: :touch, maker_fee_rate: nil,
      funding_bps_per_interval: nil, funding_interval_seconds: nil,
      min_roi_schedule: nil, liquidation_buffer: nil, stoploss_guard: nil, max_drawdown: nil,
      trailing_giveback: nil, min_confidence: nil, logger: Rails.logger)
      # Trailing profit-giveback parity: an explicit policy instance, like
      # liquidation_buffer and stoploss_guard. nil leaves it inert.
      @trailing_giveback = trailing_giveback
      @symbol = symbol
      @strategy = strategy || Trading::StrategyFactory.multi_timeframe(resolve_symbols: false)
      @step = step
      @step_scope = STEP_SCOPES.fetch(step) { raise ArgumentError, "unknown step #{step.inspect}" }
      @starting_equity = starting_equity.to_f
      # Per-venue fee (issue #458): dated futures (oil NOL, metals) pay their real
      # per-contract fee, not the perp ~3 bps. fee_for resolves it from @symbol.
      venue_fee = CostModel.fee_for(@symbol)
      @fee_rate = (fee_rate || venue_fee[:taker_rate]).to_f
      # Issue #471: the venue fee is a SHAPE, not a rate. fee_for returns a
      # per-contract dollar floor for BOTH venues — $0.85 on dated (measured
      # from real fills, #458) and $0.15 on perps — and keeping only :taker_rate
      # threw it away.
      #
      # The rates are calibrated so the floor roughly matches the proportional
      # fee at each venue's TYPICAL notional (9 bps on a ~$930 oil contract is
      # ~$0.84 against a $0.85 floor). It binds hard on SMALL-notional
      # contracts: a ~$100 nano pays $0.09 proportional against that same $0.85
      # floor — 9x — which is exactly the structural expense ADR 0002 found
      # when taker costs consumed the edge.
      # An explicit fee override replaces the venue's fee model WHOLESALE, not
      # half of it: passing fee_rate: 0.0 to isolate PnL mechanics must mean
      # zero fees, not "zero rate but still pay the floor". Callers who want a
      # floor with a custom rate pass per_contract_fee: explicitly.
      @per_contract_fee =
        if per_contract_fee
          per_contract_fee.to_f
        elsif fee_rate.nil?
          venue_fee[:per_contract_fee]&.to_f
        end
      @slippage = slippage.to_f
      # Resting-limit replay (issue #568). :through_price flips the simulator
      # to maker semantics AND changes the engine's quoting protocol below:
      # quotes derive from the PREVIOUS bar and live for exactly one bar. The
      # two halves are one fill model — quoting off the same bar that fills
      # you is look-ahead, and a quote that rests forever is a stale band.
      @fill_model = fill_model
      @maker_fee_rate = maker_fee_rate
      # Perp funding (issue #391): a constant *adverse* sensitivity knob, ON by
      # default so backtests stop silently pricing funding as free (ADR 0002).
      # Hourly; set funding_bps_per_interval: 0 to disable.
      #
      # The default is now DERIVED from this product's observed funding rows
      # rather than hardcoded at 2.0 bps. 2.0 was 21x BIP's measured 0.0938
      # bps/hr, and because funding history cannot be reconstructed, that
      # constant priced ~364 of any 370-day window. Getting it wrong by 21x
      # penalises long-hold shapes hardest, so it could decide a target-shape
      # comparison on its own (#485). Making the safe value the DEFAULT means a
      # caller has to opt into being wrong rather than remember to be right.
      #
      # Falls back to the old 2.0 only when a product has no observations at
      # all — in which case CostModel.perp? also reports "not a perp" and the
      # rate is discarded below, so the value is inert.
      observed_bps = Funding::Schedule.observed_fallback_rate(product_id: @symbol)&.*(10_000.0)
      funding_bps = (funding_bps_per_interval || ENV["BACKTEST_FUNDING_BPS_PER_INTERVAL"] ||
                     observed_bps || DEFAULT_FUNDING_BPS_PER_INTERVAL).to_f
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
      # Engine-level confidence filter (issue #580): the #497 incumbent is
      # 200/120 @ conf>=30, but the engine traded every signal, so the gates
      # could never judge the configuration as frozen. When set, a signal whose
      # :confidence is below the bar is NOT traded, only counted
      # (rejected_low_confidence in the result). The threshold is INCLUSIVE
      # (conf >= min trades). A signal with NO confidence is REJECTED when the
      # filter is set — a filter that passes unknowns is not a filter. Default
      # nil = today's behavior exactly: every signal trades, counter stays 0.
      @min_confidence = min_confidence&.to_f
      # Escape hatch (issue #387): lets a run fall back to the per-step database
      # reads, which is how the preloaded path is proved equivalent rather than
      # merely faster.
      @preload_candles = preload_candles
      @logger = logger
    end

    # Issue #387: the strategy read ~6 queries per STEP. Serve the whole run
    # from memory instead — one query per timeframe — which is what makes
    # year-long windows and bigger calibration grids affordable. The strategy
    # itself is untouched (#297 parity): only where it reads candles changes.
    def preload_candles!(from, to)
      return unless @preload_candles
      return unless @strategy.respond_to?(:candle_source=) && @strategy.respond_to?(:warmup_candles)

      @strategy.candle_source = Signals::CandleSource::Preloaded.for_run(
        symbol: @symbol, from: from, to: to, warmup_candles: @strategy.warmup_candles
      )
    end

    # The per-side rate the break-even gate should use: the engine's resolved
    # rate, with the per-contract floor folded in as a rate (break-even reasons
    # in prices and cannot take a dollar floor). Mirrors
    # CostModel.effective_taker_rate, but off the engine's OWN resolved values so
    # an override applies to the gate too.
    def break_even_fee_rate
      return @fee_rate if @per_contract_fee.nil? || @per_contract_fee <= 0
      return @fee_rate if @contract_size_usd.nil? || @contract_size_usd <= 0

      [@fee_rate, @per_contract_fee / @contract_size_usd].max
    end

    def run(from:, to:)
      # One funding source for the whole run: prices accrual from the live
      # FundingRate snapshots (issue #391, ADR 0002 guardrail), falling back to
      # the constant knob for boundaries with no observation. Candle.symbol IS the
      # product_id, so @symbol keys FundingRate directly. The SAME object feeds the
      # strategy's break-even gate below, so accrual and the gate can never desync.
      # Only PERPS have funding. Coinbase has no oil/metals perp — those trade as
      # dated futures (NOL/GOL/SLR...) with zero funding. A product is a perp iff
      # it has snapshotted FundingRate history; for dated products the constant
      # fallback is suppressed so we never charge phantom funding (fee truth #391).
      constant_rate = perp?(@symbol) ? @funding_rate_per_interval : nil
      funding_schedule = Funding::Schedule.for(product_id: @symbol,
        constant_rate_per_interval: constant_rate,
        constant_interval_seconds: @funding_interval_seconds, logger: @logger)
      @strategy.funding_schedule = funding_schedule if @strategy.respond_to?(:funding_schedule=)
      preload_candles!(from, to)
      # The gate and the fill must price the same fee (issue #459). Without
      # this, an engine-level fee override changed what fills cost but not what
      # the break-even gate demanded.
      @strategy.fee_rate = break_even_fee_rate if @strategy.respond_to?(:fee_rate=)

      sim = PaperTrading::ExchangeSimulator.new(starting_equity_usd: @starting_equity,
        fee_rate: @fee_rate, per_contract_fee: @per_contract_fee,
        contract_size_usd: @contract_size_usd, slippage: @slippage,
        funding_schedule: funding_schedule,
        fill_model: @fill_model, maker_fee_rate: @maker_fee_rate)
      equity_curve = [@starting_equity]
      entered_at = {}
      exited_at = {}
      protection_store = Trading::ProtectionLock::MemoryStore.new
      losing_exits = []
      halts = []
      @rejected_low_confidence = 0
      equity_points = [{at: from, equity: @starting_equity}]

      contracts_at = {}
      giveback_peaks = {}

      prev_candle = nil
      step_candles(from, to).each do |candle|
        # Through-price mode quotes off the last COMPLETED bar: the bar being
        # replayed is what fills the quote, so deriving the quote from it
        # would let the close place a limit its own low then "fills".
        signal_as_of = through_price? ? prev_candle&.timestamp : candle.timestamp
        maybe_enter(sim, candle, entered_at, protection_store, signal_as_of, contracts_at) if signal_as_of
        # Liquidation buffer takes precedence over the sim's TP/SL pass — a candle
        # that would liquidate closes at the buffered price first.
        maybe_liquidation_exit(sim, candle)
        # Trailing giveback owns upside exits, so it runs ahead of the sim's TP/SL
        # pass. The strategy's sl still applies below if the trail does not fire.
        maybe_trailing_giveback_exit(sim, candle, contracts_at, giveback_peaks)
        sim.on_candle(candle)
        # A quote gets exactly one bar to fill, then the band it priced is
        # stale — cancel so the next flat bar re-quotes off fresh data.
        cancel_unfilled_quotes(sim) if through_price?
        maybe_min_roi_exit(sim, candle, entered_at)
        stamp_exits(sim, candle, exited_at, protection_store, losing_exits, halts)
        equity_curve << sim.equity_usd
        equity_points << {at: candle.timestamp, equity: sim.equity_usd}
        maybe_max_drawdown_halt(candle, equity_points, protection_store, halts)
        prev_candle = candle
      end

      Result.new(trades: build_trades(sim, entered_at, exited_at),
        equity_curve: equity_curve, starting_equity: @starting_equity, from: from, to: to,
        protection_halts: halts, rejected_low_confidence: @rejected_low_confidence)
    end

    private

    # A perp iff Coinbase advertised funding for it (snapshotted FundingRate rows
    # exist). Dated futures never have funding.
    def perp?(symbol)
      FundingRate.for_product(symbol).exists?
    end

    def step_candles(from, to)
      Candle.for_symbol(@symbol).public_send(@step_scope)
        .where(timestamp: from..to).order(:timestamp)
    end

    def through_price?
      @fill_model == :through_price
    end

    def cancel_unfilled_quotes(sim)
      sim.orders.values.each { |o| sim.cancel(o.id) if o.status == :open }
    end

    # One position at a time: only ask the strategy while flat.
    def maybe_enter(sim, candle, entered_at, protection_store, signal_as_of, contracts_at = {})
      return if position_active?(sim)

      sig = @strategy.signal(symbol: @symbol, equity_usd: sim.equity_usd, as_of: signal_as_of)
      return unless sig && sig[:quantity].to_f > 0

      # Min-confidence filter (issue #580): drop the signal BEFORE simulated
      # entry, and count it so the filter's selectivity is visible in reports.
      if below_min_confidence?(sig)
        @rejected_low_confidence += 1
        return
      end

      # Protections parity: a symbol/side under an active lock produces no entry,
      # evaluated on the simulated clock against the run-local store.
      return if Trading::Protections.blocked?(symbol: @symbol, side: sig[:side].to_s,
        now: candle.timestamp, store: protection_store)

      base_qty = contracts_to_base_units(sig[:quantity], sig[:price])
      return unless base_qty > 0

      # Same suppression as the live path: the strategy's tp fires ~5x sooner than
      # the trail's arm threshold, so handing it to the sim means the peak never
      # reaches the arm and the trail never fires. sl is left in place.
      tp = sig[:tp] unless @trailing_giveback&.enabled?

      id = sim.place_limit(symbol: @symbol, side: SideNormalizer.simulator_fill_side(sig[:side]),
        price: sig[:price], quantity: base_qty, tp: tp, sl: sig[:sl])
      entered_at[id] = candle.timestamp
      # Contracts, not base units: the policy's thresholds are per contract, and
      # base_qty has already been scaled by contract_size_usd / price.
      contracts_at[id] = sig[:quantity].to_f
    end

    # Inclusive bar: conf >= @min_confidence trades (the incumbent is
    # "conf>=30"). nil confidence is REJECTED when the filter is set — a
    # filter that passes unknowns is not a filter.
    def below_min_confidence?(sig)
      return false if @min_confidence.nil?

      conf = sig[:confidence]
      conf.nil? || conf.to_f < @min_confidence
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

    # Trailing profit-giveback parity with the live tick path. Arms once net profit
    # per contract clears the threshold, then closes on giving back a fraction of
    # the peak; unarmed, only the flat per-contract stop applies.
    #
    # A candle is a range, not a point, and which end is used matters:
    #   peak  <- the FAVORABLE extreme (high for a long). Taking the peak from the
    #            close would systematically understate the tick-level peak the live
    #            path sees, arming later and exiting at a lower floor.
    #   exit  <- the ADVERSE extreme, and the fill is taken there too. A real stop
    #            would fill nearer the floor than the bar's worst price, so this is
    #            deliberately pessimistic rather than flattering.
    def maybe_trailing_giveback_exit(sim, candle, contracts_at, peaks)
      return unless @trailing_giveback&.enabled?

      sim.orders.values.each do |o|
        next unless o.status == :filled

        entry = (o.entry_fill || o.price).to_f
        next unless entry.positive?

        contracts = contracts_at[o.id].to_f
        next unless contracts.positive?

        long = o.side == :buy
        direction = long ? 1.0 : -1.0
        qty = o.quantity.to_f
        gross_at = ->(price) { (price - entry) * qty * direction }

        favorable = (long ? candle.high : candle.low).to_f
        adverse = (long ? candle.low : candle.high).to_f

        # Seed from the first favorable extreme rather than 0, so an underwater
        # position does not get a phantom $0 peak it never actually reached.
        favorable_gross = gross_at.call(favorable)
        peak = peaks.key?(o.id) ? [peaks[o.id].to_f, favorable_gross].max : favorable_gross
        peaks[o.id] = peak

        # An explicit fee_rate override replaces the venue's model wholesale, which
        # is why the per-contract floor is only applied when one is actually set.
        round_trip = CostModel.round_trip_cost(
          entry_price: entry, exit_price: entry, quantity: qty, fee_rate: @fee_rate,
          contracts: @per_contract_fee ? contracts : nil, per_contract_fee: @per_contract_fee
        )

        reason = @trailing_giveback.exit_reason(
          net_pnl: gross_at.call(adverse) - round_trip,
          peak_net_pnl: peak - round_trip,
          contracts: contracts
        )
        next unless reason

        sim.force_close(o.id, price: adverse, reason: reason, candle: candle)
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
