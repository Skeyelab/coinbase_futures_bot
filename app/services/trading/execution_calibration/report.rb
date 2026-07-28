# frozen_string_literal: true

module Trading
  module ExecutionCalibration
    # The written finding. This IS the deliverable of issue #486 — the orders
    # are only how the numbers are obtained.
    Report = Struct.new(
      :status, :mode, :product_id, :tape, :breach, :refusals,
      :reconciliation, :maker_warning, :started_at, :finished_at
    ) do
      def refused? = status == :refused

      def aborted? = status == :aborted

      def to_h
        {
          status: status,
          mode: mode,
          product_id: product_id,
          refusals: Array(refusals),
          breach: breach && {condition: breach.condition, reason: breach.reason},
          legs: tape ? tape.legs.size : 0,
          taker_attempts: tape ? tape.taker_attempts.size : 0,
          maker_attempts: tape ? tape.maker_attempts.size : 0,
          maker_fills: tape ? tape.maker_fills.size : 0,
          maker_fill_rate: tape&.maker_fill_rate,
          measured_taker_rate_bps: bps(tape&.measured_taker_rate),
          measured_maker_rate_bps: bps(tape&.measured_maker_rate),
          modeled_taker_rate_bps: bps(reconciliation&.dig(:modeled_rate)),
          reconciliation: reconciliation,
          realized_pnl: tape&.realized_pnl,
          total_commission: tape&.total_commission,
          slippage_bps: slippage_summary,
          funding: funding_summary,
          maker_warning: maker_warning,
          adr_0002_verdict: adr_verdict,
          started_at: started_at&.utc&.iso8601,
          finished_at: finished_at&.utc&.iso8601
        }
      end

      # Plain text, because the operator reading this after a $150 run is
      # reading a terminal, and because it has to be pasteable into #486.
      def summary
        lines = ["BIP EXECUTION CALIBRATION — issue #486", "=" * 60,
          "status        : #{status}#{" (#{mode})" if mode}",
          "instrument    : #{product_id}"]

        return (lines + ["", "REFUSED TO START:"] + Array(refusals).map { |r| "  - #{r}" }).join("\n") if refused?

        lines += [
          "round trips   : #{tape.legs.size} (#{tape.taker_attempts.size} taker-entry, #{tape.maker_attempts.size} maker-entry)",
          "",
          "FEES",
          "  measured taker rate : #{fmt_bps(tape.measured_taker_rate)} across #{tape.taker_fills.size} taker fills",
          "  modeled taker rate  : #{fmt_bps(reconciliation&.dig(:modeled_rate))} (CostModel)",
          "  reconciliation      : #{reconciliation_line}",
          "  measured maker rate : #{fmt_bps(tape.measured_maker_rate)}",
          "  total commission    : #{format("$%.4f", tape.total_commission)}",
          "",
          "MAKER FILLS",
          "  maker fill rate     : #{maker_rate_line}",
          "  #{maker_warning || "at or above the 30% floor — the +22 bps maker case survives"}",
          "",
          "SLIPPAGE",
          "  slippage distribution : #{slippage_line}",
          "",
          "FUNDING",
          "  funding modeled vs debited : #{funding_line}",
          "",
          "P&L",
          "  realized            : #{format("$%+.2f", tape.realized_pnl)} " \
          "(authorized loss #{format("$%.0f", AbortConditions::CUMULATIVE_LOSS_USD)})"
        ]

        lines += ["", "ABORTED — #{breach.condition}", "  #{breach.reason}"] if aborted?
        lines += ["", "ADR 0002 VERDICT", "  #{adr_verdict}"]
        lines.join("\n")
      end

      # The question #486 was opened to answer. Deliberately refuses to answer
      # it from a dry run: simulated commissions are CostModel's own numbers
      # played back, so a dry run "confirming" the model confirms nothing.
      def adr_verdict
        return "NOT ANSWERED — the run refused to start; no fills were observed." if refused?
        if mode == :dry_run
          return "NOT ANSWERED — dry-run fills are the model played back to itself, not evidence. " \
            "ADR 0002's ~3 bps perp taker rate remains UNVALIDATED against real fills."
        end

        measured = tape&.measured_taker_rate
        return "NOT ANSWERED — no taker fill produced a usable notional." if measured.nil?

        if measured * 10_000.0 > AbortConditions::TAKER_RATE_BPS
          "FALSIFIED — measured #{fmt_bps(measured)} taker against ADR 0002's ~3 bps. The perp thesis " \
            "(dated -9 bps -> perp +15 bps) does not survive contact with real fills. Re-open the venue decision."
        elsif maker_warning
          "SURVIVES ON TAKER COST ONLY — measured #{fmt_bps(measured)} taker is consistent with ADR 0002, " \
            "but the maker fill rate kills the +22 bps upgrade. Re-run the economics taker-only."
        else
          "SURVIVES — measured #{fmt_bps(measured)} taker is consistent with ADR 0002's ~3 bps, and the maker " \
            "fill rate clears the floor. This is the first real validation of the venue thesis."
        end
      end

      private

      def bps(rate) = rate.nil? ? nil : (rate.to_f * 10_000.0).round(3)

      def fmt_bps(rate) = rate.nil? ? "n/a" : "#{(rate.to_f * 10_000.0).round(2)} bps"

      def reconciliation_line
        return "not computed" unless reconciliation

        verdict = reconciliation[:within_tolerance] ? "WITHIN 10%" : "OUTSIDE 10%"
        "#{verdict} (#{(reconciliation[:relative_drift].to_f * 100).round(1)}% off) — #376 gate 1"
      end

      def maker_rate_line
        rate = tape&.maker_fill_rate
        return "not measured (no maker entry attempted)" if rate.nil?
        return "not meaningful in dry-run — the simulator always fills" if mode == :dry_run

        "#{(rate * 100).round(1)}% (#{tape.maker_fills.size}/#{tape.maker_attempts.size})"
      end

      def slippage_summary
        values = tape&.fills&.map { |f| f.slippage_bps.round(3) } || []
        return {count: 0} if values.empty?

        sorted = values.sort
        {count: values.size, min: sorted.first, median: sorted[sorted.size / 2], max: sorted.last,
         mean: (values.sum / values.size).round(3), worst_abs: tape.worst_slippage_bps.round(3)}
      end

      def slippage_line
        s = slippage_summary
        return "no fills observed" if s[:count].zero?

        "#{s[:count]} fills — min #{s[:min]} / median #{s[:median]} / max #{s[:max]} bps " \
          "(mean #{s[:mean]}, worst absolute #{s[:worst_abs]}; abort threshold #{AbortConditions::SLIPPAGE_BPS})"
      end

      def funding_summary
        {modeled_usd: tape&.funding_modeled, debited_usd: tape&.funding_debited,
         observed: tape ? tape.legs.any? { |l| l.funding_modeled.to_f.abs.positive? } : false}
      end

      def funding_line
        f = funding_summary
        unless f[:observed]
          return "no funding boundary was crossed by any hold — funding is UNMEASURED by this run. " \
            "ADR 0002's 0.1-0.5 bps/trade funding estimate is untested; a longer-hold run is needed."
        end

        "modeled #{format("$%+.4f", f[:modeled_usd].to_f)} vs debited " \
          "#{f[:debited_usd].nil? ? "not observable from the order path" : format("$%+.4f", f[:debited_usd].to_f)}"
      end
    end
  end
end
