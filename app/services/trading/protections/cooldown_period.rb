# frozen_string_literal: true

module Trading
  module Protections
    # CooldownPeriod (issue #397, ADR 0003). After any position exit, block new
    # entries on that symbol for a configurable window so the bot does not
    # immediately re-enter the conditions it just left. Side-agnostic: a cooldown
    # blocks both long and short re-entry on the symbol.
    #
    # Triggered from the position-exit path via .record_exit. Duration comes from
    # config (real_time_signals[:protections][:cooldown_seconds]) with a per-call
    # override for callers that resolve a per-symbol TradingProfile value.
    module CooldownPeriod
      SOURCE = "CooldownPeriod"
      DEFAULT_COOLDOWN_SECONDS = 300

      module_function

      def record_exit(symbol:, cooldown_seconds: default_cooldown_seconds, now: Time.current)
        Trading::ProtectionLock.add(
          scope: "symbol",
          symbol: symbol,
          side: "both",
          source: SOURCE,
          reason: "cooldown after exit",
          expires_at: now + cooldown_seconds.seconds
        )
      end

      def default_cooldown_seconds
        config = Rails.application.config.try(:real_time_signals) || {}
        config.dig(:protections, :cooldown_seconds) || DEFAULT_COOLDOWN_SECONDS
      end
    end
  end
end
