# frozen_string_literal: true

module Trading
  module ExecutionCalibration
    # Issue #486's abort conditions. Any one of them halts the run immediately
    # via a NON-EXPIRING risk halt, which requires an acknowledged clear.
    #
    # Detection and halting live in the same object on purpose. Split apart,
    # "detected the breach" and "actually stopped trading" become two facts, and
    # this codebase has already shipped the version where only the first one is
    # true (#396-#401 wrote protection locks nothing read; two emergency stops
    # reported closes they never made). Every condition here has a spec that
    # asserts TradingHalt.risk_halted? afterwards.
    class AbortConditions
      SLIPPAGE_BPS = 25.0
      # 5 bps is the falsification threshold, not a risk limit: ADR 0002 priced
      # the perp venue at ~3 bps taker and concluded the strategy flips from
      # -9 bps to +15 bps net on that number. Above 5 bps the conclusion does
      # not hold and the venue decision has to be re-opened.
      TAKER_RATE_BPS = 5.0
      CUMULATIVE_LOSS_USD = Preflight::AUTHORIZED_LOSS_USD
      # Reported prominently but never aborts (#486): a poor maker fill rate
      # kills the +22 bps maker case, which is a finding, not an emergency.
      MAKER_FILL_RATE_FLOOR = 0.30
      # PaperTrading::ExchangeSimulator stamps every simulated order with this
      # prefix (see Trading::CoinbasePositions#simulate_order).
      SIMULATED_ORDER_PREFIX = "DRY-RUN-"

      # `halts` distinguishes two kinds of abort that were previously conflated:
      # "this instrument is unsafe to trade" (halt — that is what a kill switch
      # is for) and "my own measurement is unusable" (stop the run, but do not
      # take the trading system down for it). On 2026-07-28 the second kind
      # raised RISK halts twice, and a RISK halt needs a console to clear
      # (#481) — so a measurement bug stopped trading until a human was found
      # (issues #535, #537).
      Breach = Struct.new(:condition, :reason, :halts) do
        def halts? = halts.nil? || halts
      end

      # `mode` is :live or :dry_run. It matters because two of these conditions
      # are claims about the VENUE, and a rehearsal has no venue in it — its
      # fills are the model played back to itself. Report#adr_verdict already
      # refuses to answer ADR 0002 in dry-run for exactly that reason; the abort
      # path did not, and wrote "FALSIFIED ... contradicted by real fills" into a
      # risk halt from simulated data (issue #535, errata on #486). The report
      # was honest and the halt was not, which is the worse way round.
      def initialize(tape:, mode: :live, logger: Rails.logger)
        @tape = tape
        @mode = mode
        @logger = logger
      end

      def dry_run? = @mode.to_s.to_sym == :dry_run

      # Returns the Breach that stopped the run, or nil. Halts on the way out.
      def enforce!
        breach = detect
        return nil unless breach

        @logger.error("[ExecutionCalibration] ABORT (#{breach.condition}) — #{breach.reason}")

        # A breach that only means "these numbers are not trustworthy" stops the
        # run without halting trading. Nothing real was placed, so there is no
        # exposure to stop; halting would only strand unrelated open positions.
        unless breach.halts?
          @logger.error("[ExecutionCalibration] run stopped WITHOUT a risk halt — " \
                        "#{breach.condition} is a measurement fault, not a trading-risk event")
          return breach
        end

        # Do not rewrite an existing risk halt: the FIRST breach is the one that
        # explains the run, and overwriting it would lose that.
        return breach if TradingHalt.risk_halted?

        TradingHalt.halt_for_risk!(reason: "#{@tape.product_id} calibration abort (#{breach.condition}): #{breach.reason}",
          logger: @logger)
        breach
      end

      # Ordered by which fact best explains the run to whoever reads the halt.
      # The taker rate leads because it is the CAUSE when it trips: a 60 bps
      # taker rate also blows the loss cap, and "cumulative loss" as the headline
      # would bury the finding this run exists to produce.
      def detect
        simulated_fills_breach || taker_rate_breach || order_integrity_breach ||
          slippage_breach || hold_overrun_breach || cumulative_loss_breach
      end

      # Reported, never aborts. nil when no maker entry was attempted yet.
      def maker_fill_rate_warning
        rate = @tape.maker_fill_rate
        return nil if rate.nil? || rate >= MAKER_FILL_RATE_FLOOR

        "maker fill rate #{(rate * 100).round(1)}% across #{@tape.maker_attempts.size} attempts is below " \
          "#{(MAKER_FILL_RATE_FLOOR * 100).round}% — this KILLS ADR 0002's +22 bps maker case; the economics " \
          "must be re-run taker-only (~+15 bps) before any maker-dependent projection is used again"
      end

      private

      # Leads detection, ahead of the taker rate, because a rate computed from
      # simulated fills is not a finding about the venue — it is a finding about
      # the simulator, and reporting it as the former is exactly what produced
      # the retracted "ADR 0002 is FALSIFIED" claim (errata on #486).
      #
      # Preflight should make this unreachable. It exists because it did happen,
      # and because dry-run can be toggled while a run is in flight. Does NOT
      # halt: nothing real was placed.
      def simulated_fills_breach
        # Expected in a rehearsal — every fill is simulated by design. In LIVE
        # it means the run believes it is measuring the venue while orders are
        # being diverted to the simulator, which is the #535 failure and makes
        # every derived rate fiction.
        return nil if dry_run?

        simulated = @tape.fills.select { |f| f.order_id.to_s.start_with?(SIMULATED_ORDER_PREFIX) }
        return nil if simulated.empty?

        Breach.new(condition: :simulated_fills, halts: false, reason:
          "#{simulated.size} of #{@tape.fills.size} fills are SIMULATED (order ids beginning " \
          "#{SIMULATED_ORDER_PREFIX}) on a run declared LIVE — orders are reaching the simulator, so no " \
          "rate derived from this run describes the venue. Not a duplicate-order fault and not a venue " \
          "finding; discard the run and fix the mode before retrying (issues #486, #535)")
      end

      def taker_rate_breach
        # A rehearsal cannot falsify ADR 0002, so it must not claim to. The
        # rate here is whatever the simulator charged; aborting on it produced
        # a "300 bps measured taker rate" that was a 100x fee bug (#531).
        return nil if dry_run?

        rate = @tape.measured_taker_rate
        return nil if rate.nil?

        bps = rate * 10_000.0
        return nil if bps <= TAKER_RATE_BPS

        Breach.new(condition: :taker_rate, reason:
          "measured perp taker rate #{bps.round(2)} bps across #{@tape.taker_fills.size} fills exceeds the " \
          "#{TAKER_RATE_BPS} bps abort threshold. ADR 0002's venue conclusion is FALSIFIED: the perp thesis " \
          "(dated -9 bps -> perp +15 bps) was priced on a ~3 bps taker rate that has just been contradicted " \
          "by real fills. Stop and re-open the venue decision (issue #486).")
      end

      def order_integrity_breach
        rejected = @tape.rejected_legs
        if rejected.any?
          return Breach.new(condition: :order_integrity, reason:
            "leg #{rejected.first.number} order failed: #{rejected.first.error}")
        end

        mis_sized = @tape.mis_sized_fills
        if mis_sized.any?
          return Breach.new(condition: :order_integrity, reason:
            "mis-sized fill: #{mis_sized.first.contracts} contracts on a run pinned to exactly 1 " \
            "(order #{mis_sized.first.order_id})")
        end

        duplicates = @tape.duplicate_order_ids
        return nil if duplicates.empty?

        Breach.new(condition: :order_integrity, reason:
          "duplicate exchange order id(s) #{duplicates.join(", ")} — the same order was recorded twice, so " \
          "the fill count and every rate derived from it are untrustworthy")
      end

      def slippage_breach
        worst = @tape.fills.max_by(&:deviation_bps)
        return nil if worst.nil? || worst.deviation_bps <= SLIPPAGE_BPS

        Breach.new(condition: :slippage, reason:
          "fill slippage #{worst.deviation_bps.round(2)} bps (#{worst.phase} #{worst.side} at " \
          "#{worst.fill_price} against an intended #{worst.intended_price}) exceeds the #{SLIPPAGE_BPS} bps limit")
      end

      def hold_overrun_breach
        overrun = @tape.overrun_legs.first
        return nil unless overrun

        Breach.new(condition: :hold_overrun, reason:
          "leg #{overrun.number} was held #{overrun.held_seconds.round}s against an intended " \
          "#{overrun.intended_hold_seconds}s — more than #{Tape::HOLD_OVERRUN_MULTIPLE}x, so the position " \
          "outlived the exit path meant to close it")
      end

      def cumulative_loss_breach
        pnl = @tape.realized_pnl
        return nil unless pnl.negative? && pnl.abs > CUMULATIVE_LOSS_USD

        Breach.new(condition: :cumulative_loss, reason:
          "cumulative realized loss #{format("$%.2f", pnl.abs)} exceeds the " \
          "#{format("$%.0f", CUMULATIVE_LOSS_USD)} authorized for this run")
      end
    end
  end
end
