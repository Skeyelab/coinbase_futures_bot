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
# A halt auto-expires after a TTL so it does not stay on forever if forgotten.
# Because the state is DB-backed, the halt now survives a process restart within
# that window (a restart no longer silently re-enables trading). Set
# TRADING_HALT_TTL_HOURS to override (default 24 hours).
class TradingHalt
  STORE_KEY = "trading_halt"
  DEFAULT_TTL_HOURS = 24

  HaltedError = Class.new(StandardError)

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

  # Resume trading after a halt.
  def self.resume!(logger: Rails.logger)
    new(logger: logger).resume!
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

    # Auto-expire a stale halt so it does not linger forever.
    recorded_at = record.recorded_at
    return true if recorded_at.present? && recorded_at < ttl.ago

    false
  end

  def halted?
    !active?
  end

  def reason
    read_record&.value&.dig("reason").presence
  end

  def halt!(reason: nil)
    write_state(halted: true, reason: reason.to_s.presence)
    @logger.warn("[TradingHalt] Trading HALTED#{": #{reason}" if reason.present?}")
    status
  end

  def resume!
    write_state(halted: false, reason: nil)
    @logger.info("[TradingHalt] Trading RESUMED")
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

  def write_state(halted:, reason:)
    record = BotRuntimeStat.find_or_initialize_by(key: STORE_KEY)
    record.value = {"halted" => halted, "reason" => reason}
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
