# frozen_string_literal: true

module Trading
  module Protections
    # Live driver for the MaxDrawdown guard (issue #401). Live equity history is
    # not persisted, so this keeps durable, timestamped equity samples in
    # bot_runtime_stats; the peak is the max within the guard's lookback window,
    # matching what Backtest::Engine#maybe_max_drawdown_halt already does.
    #
    # Three lessons from issue #608 are load-bearing here:
    #
    #   1. The samples are SCOPED TO THE EQUITY REGIME (paper vs live). A $4,987
    #      peak from the CFM balance once survived a switch to dry-run and read
    #      the $373 paper account as a 92.5% crash — a permanent false halt. A
    #      peak from a different account is not a peak.
    #   2. The peak ages out. It was a monotonic all-time max, so a poisoned or
    #      ancient peak could never self-heal, and the documented 24h lookback
    #      was a live/backtest parity break.
    #   3. A halt is a STATE. Alert on the transition into it, plus at most one
    #      reminder per day — not once per lock TTL, which was ~48 warnings/day.
    module MaxDrawdownMonitor
      PEAK_KEY = "protection:max_drawdown_peak"
      # 5-minute sample buckets: fine enough for a 24h window, coarse enough
      # that a 30s evaluation cycle does not grow the record without bound.
      BUCKET_SECONDS = 300
      REMINDER_SECONDS = 86_400

      module_function

      def evaluate(current_equity:, now: Time.current, store: Trading::ProtectionLock.default_store,
        logger: Rails.logger)
        return [] if current_equity.nil?

        guard = Trading::Protections::MaxDrawdown.from_config
        return [] unless guard.enabled?

        state = read_state
        samples = record_sample(state, current_equity.to_f, now, guard.lookback_seconds)
        peak = samples.values.max

        locks = guard.evaluate(peak: peak, current: current_equity.to_f, now: now, store: store)
        breached = guard.drawdown(peak: peak, current: current_equity.to_f) > 0 &&
          (locks.any? || Trading::Protections.blocked?(symbol: "ANY", side: "long"))
        alert!(state, locks, peak, now, logger) if locks.any?
        write_state(state.merge("samples" => samples, "breached" => locks.any? || breached))
        locks
      end

      # Alert on the transition into breach, or as a daily reminder while one
      # persists. Lock re-creation after TTL expiry is neither.
      def alert!(state, locks, peak, now, logger)
        last_alert = state["alerted_at"] && Time.zone.parse(state["alerted_at"])
        in_episode = state["breached"]
        return if in_episode && last_alert && now - last_alert < REMINDER_SECONDS

        locks.each do |lock|
          logger.warn("[MaxDrawdown] global halt: #{lock["reason"]}")
          SlackNotificationService.alert("warning", "MaxDrawdown halt",
            "Trading halted — equity drawdown from peak ($#{peak.round(2)}) breached the ceiling: #{lock["reason"]}.")
        end
        state["alerted_at"] = now.utc.iso8601
      end

      # Bucketed, pruned, regime-checked samples. A regime flip discards the
      # history wholesale: comparing paper equity to a live peak is not a
      # drawdown, it is a category error.
      def record_sample(state, equity, now, lookback_seconds)
        samples = (state["regime"] == regime) ? (state["samples"] || {}) : {}
        state["regime"] = regime
        cutoff = now.to_i - lookback_seconds
        bucket = (now.to_i / BUCKET_SECONDS) * BUCKET_SECONDS

        samples = samples.select { |at, _| at.to_i >= cutoff }
        samples[bucket.to_s] = [samples[bucket.to_s].to_f, equity].max
        samples
      end

      def regime
        DryRun.active? ? "paper" : "live"
      end

      # The current in-window peak for display (OperatorSnapshot). nil when no
      # sample from THIS regime is inside the window -- a stale or cross-regime
      # peak is exactly the number #608 says never to show.
      def current_peak(now: Time.current)
        state = read_state
        return nil unless state["regime"] == regime

        lookback = Trading::Protections::MaxDrawdown.from_config.lookback_seconds
        cutoff = now.to_i - lookback
        in_window = (state["samples"] || {}).select { |at, _| at.to_i >= cutoff }
        in_window.values.max
      end

      def read_state
        BotRuntimeStat.find_by(key: PEAK_KEY)&.value || {}
      end

      def write_state(state)
        # Atomic upsert (#546): written every ~30s monitor cycle; the
        # find_or_initialize insert race on this exact key is the deadlock
        # that flaked CI on PR #545.
        BotRuntimeStat.upsert_value!(key: PEAK_KEY, value: state)
      end
    end
  end
end
