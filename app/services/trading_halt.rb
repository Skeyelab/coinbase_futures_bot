# frozen_string_literal: true

# TradingHalt is the single source of truth for the kill switch / trading halt
# mechanism. State is persisted in the +bot_runtime_stats+ table under the
# +STORE_KEY+ key, so it is durable and shared across every process (CLI, TUI,
# chat session, background jobs) on the machine:
#
#   value: {"halted" => Boolean, "reason" => Optional String}
#   recorded_at: when the halt/resume was recorded (used for TTL expiry)
#
# Reads are DB-authoritative — deliberately NOT cache-first. A kill switch read
# from a per-process cache would let one process keep trading after another
# process halted it (the cache would still say "active"). Order placement is
# infrequent relative to a DB read, so authoritative reads are the correct
# trade-off.
#
# All order-placement code (FuturesExecutor, Trading::CoinbasePositions, etc.)
# should call TradingHalt.active? / assert_active! before submitting any order.
# Rake tasks, the CLI, and chat surface halt/resume/status via TradingHalt.
#
# Halts come in two kinds, because they answer different questions (issue #481):
#
#   OPERATIONAL — "pause while the CPI print lands". Auto-expires after a TTL so
#                 it does not stay on forever if someone forgets. This was the
#                 only kind, and the TTL is correct for it.
#   RISK        — "the loss cap tripped". NEVER expires, and clearing it takes an
#                 explicit acknowledgement that is recorded.
#
# The distinction exists because a 24h TTL on a risk halt is not a control: a
# halt triggered by hitting a loss limit would silently self-resume and trade
# again the next day. #392 condition 3 asks for "auto-halt to paper, no
# override", which is unbuildable on a primitive that forgets.
#
# Because the state is DB-backed, a halt survives a process restart either way.
# Set TRADING_HALT_TTL_HOURS to override the operational TTL (default 24 hours).
class TradingHalt
  STORE_KEY = "trading_halt"
  DEFAULT_TTL_HOURS = 24

  OPERATIONAL = "operational"
  RISK = "risk"

  HaltedError = Class.new(StandardError)
  # Raised when something tries to clear a risk halt without acknowledging it.
  RiskHaltError = Class.new(StandardError)

  # Returns true when trading is enabled (default state).
  def self.active?
    new.active?
  end

  # Returns true when trading is halted.
  def self.halted?
    new.halted?
  end

  # Halt trading. Raises nothing — safe to call from rescue blocks.
  def self.halt!(reason: nil, logger: Rails.logger)
    new(logger: logger).halt!(reason: reason)
  end

  # Halt on a risk trigger: never expires, and clearing it requires an
  # acknowledged, recorded operator action.
  def self.halt_for_risk!(reason:, logger: Rails.logger)
    new(logger: logger).halt_for_risk!(reason: reason)
  end

  def self.risk_halted?
    new.risk_halted?
  end

  # Resume trading after a halt. A risk halt requires acknowledge_risk: true.
  def self.resume!(acknowledge_risk: false, operator: nil, logger: Rails.logger)
    new(logger: logger).resume!(acknowledge_risk: acknowledge_risk, operator: operator)
  end

  # Returns a status hash suitable for display or JSON serialisation.
  def self.status
    new.status
  end

  # Raise HaltedError unless trading is active. Call this at the top of any
  # method that would place or modify an order.
  def self.assert_active!(context: nil)
    new.assert_active!(context: context)
  end

  def initialize(logger: Rails.logger)
    @logger = logger
  end

  def active?
    record = read_record
    return true if record.nil?
    return true unless halted_value?(record)

    # A risk halt never expires — that is the entire point of the distinction.
    return false if kind_value(record) == RISK

    # Auto-expire a stale OPERATIONAL halt so it does not linger forever.
    recorded_at = record.recorded_at
    return true if recorded_at.present? && recorded_at < ttl.ago

    false
  end

  def risk_halted?
    record = read_record
    return false if record.nil? || !halted_value?(record)

    kind_value(record) == RISK
  end

  def kind
    record = read_record
    return nil if record.nil? || !halted_value?(record)

    kind_value(record)
  end

  def halted?
    !active?
  end

  def reason
    read_record&.value&.dig("reason").presence
  end

  def halt!(reason: nil)
    # An operational halt must not downgrade an active risk halt — otherwise a
    # routine pause/resume cycle would quietly clear a loss-cap trip.
    return status if risk_halted?

    write_state(halted: true, reason: reason.to_s.presence, kind: OPERATIONAL)
    @logger.warn("[TradingHalt] Trading HALTED#{": #{reason}" if reason.present?}")

    # PostHog: Track trading halt
    PostHog.capture(
      distinct_id: "system",
      event: "trading_halted",
      properties: {reason: reason.to_s.presence}
    )

    status
  end

  def halt_for_risk!(reason:)
    write_state(halted: true, reason: reason.to_s.presence, kind: RISK)
    @logger.error("[TradingHalt] RISK HALT — trading stopped until explicitly cleared: #{reason}")

    PostHog.capture(
      distinct_id: "system",
      event: "trading_risk_halted",
      properties: {reason: reason.to_s.presence}
    )

    status
  end

  def resume!(acknowledge_risk: false, operator: nil)
    record = read_record
    prior_reason = record&.value&.dig("reason")
    prior_kind = (record && halted_value?(record)) ? kind_value(record) : nil

    if prior_kind == RISK && !acknowledge_risk
      raise RiskHaltError,
        "Trading is under a RISK halt (#{prior_reason}). Clearing it requires " \
        "acknowledge_risk: true and an operator — this is deliberate, see issue #481."
    end

    cleared = if prior_kind == RISK
      {"at" => Time.current.utc.iso8601, "operator" => operator.to_s.presence,
       "prior_reason" => prior_reason, "prior_kind" => prior_kind}
    end

    write_state(halted: false, reason: nil, kind: nil, last_cleared: cleared)
    @logger.info("[TradingHalt] Trading RESUMED#{" (risk halt cleared by #{operator})" if cleared}")

    # PostHog: Track trading resume
    PostHog.capture(
      distinct_id: "system",
      event: "trading_resumed",
      properties: {}
    )

    status
  end

  def assert_active!(context: nil)
    return if active?

    msg = "Trading is halted"
    current_reason = reason
    msg += " (#{current_reason})" if current_reason.present?
    msg += " [#{context}]" if context.present?
    raise HaltedError, msg
  end

  def status
    halted = halted?
    {
      active: !halted,
      halted: halted,
      reason: reason,
      kind: kind,
      as_of: Time.current.utc.iso8601
    }
  end

  private

  def read_record
    BotRuntimeStat.find_by(key: STORE_KEY)
  end

  def halted_value?(record)
    value = record.value || {}
    !!value["halted"]
  end

  # Absent kind means a halt written before #481 — treat it as operational so
  # existing state keeps its old expiry behaviour rather than becoming permanent.
  def kind_value(record)
    (record.value || {})["kind"].presence || OPERATIONAL
  end

  def write_state(halted:, reason:, kind: nil, last_cleared: nil)
    record = BotRuntimeStat.find_or_initialize_by(key: STORE_KEY)
    value = {"halted" => halted, "reason" => reason, "kind" => kind}
    # Preserve the clearing record across subsequent writes so the audit trail
    # is not erased by the next ordinary halt.
    prior_cleared = (record.value || {})["last_cleared"]
    value["last_cleared"] = last_cleared || prior_cleared
    record.value = value.compact
    record.recorded_at = Time.current.utc
    record.save!
  rescue ActiveRecord::RecordNotUnique
    retry
  end

  def ttl
    hours = (ENV["TRADING_HALT_TTL_HOURS"] || DEFAULT_TTL_HOURS).to_i
    hours.hours
  end
end
