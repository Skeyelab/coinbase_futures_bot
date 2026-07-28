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

      Breach = Struct.new(:condition, :reason)

      def initialize(tape:, logger: Rails.logger)
        @tape = tape
        @logger = logger
      end

      # Returns the Breach that stopped the run, or nil. Halts on the way out.
      def enforce!
        breach = detect
        return nil unless breach

        @logger.error("[ExecutionCalibration] ABORT (#{breach.condition}) — #{breach.reason}")

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
        taker_rate_breach || order_integrity_breach || slippage_breach ||
          hold_overrun_breach || cumulative_loss_breach
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

      def taker_rate_breach
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
