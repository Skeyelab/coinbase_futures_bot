# frozen_string_literal: true

module Trading
  module Protections
    # Live driver for the MaxDrawdown guard (issue #401). Live equity history is
    # not persisted, so this keeps a durable running peak in bot_runtime_stats
    # (the TradingHalt / ProtectionLock pattern); drawdown from that peak is the
    # equity-curve drawdown. Call once per evaluation cycle with the current
    # equity; on a breach it writes the global halt and fires a Slack warning.
    #
    # (In backtest the engine drives the same MaxDrawdown guard directly off the
    # run's equity_curve — see Backtest::Engine#maybe_max_drawdown_halt.)
    module MaxDrawdownMonitor
      PEAK_KEY = "protection:max_drawdown_peak"

      module_function

      def evaluate(current_equity:, now: Time.current, store: Trading::ProtectionLock.default_store,
        logger: Rails.logger)
        return [] if current_equity.nil?

        guard = Trading::Protections::MaxDrawdown.from_config
        return [] unless guard.enabled?

        peak = [read_peak, current_equity.to_f].compact.max
        write_peak(peak)

        locks = guard.evaluate(peak: peak, current: current_equity.to_f, now: now, store: store)
        locks.each do |lock|
          logger.warn("[MaxDrawdown] global halt: #{lock["reason"]}")
          SlackNotificationService.alert("warning", "MaxDrawdown halt",
            "Trading halted — equity drawdown from peak ($#{peak.round(2)}) breached the ceiling: #{lock["reason"]}.")
        end
        locks
      end

      def read_peak
        BotRuntimeStat.find_by(key: PEAK_KEY)&.value&.dig("peak")
      end

      def write_peak(peak)
        record = BotRuntimeStat.find_or_initialize_by(key: PEAK_KEY)
        record.value = {"peak" => peak}
        record.recorded_at = Time.current.utc
        record.save!
      rescue ActiveRecord::RecordNotUnique
        retry
      end
    end
  end
end
