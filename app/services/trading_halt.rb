# frozen_string_literal: true

# TradingHalt is the single source of truth for the kill switch / trading halt
# mechanism. It reads and writes two Rails.cache keys:
#
#   "trading_active"   – Boolean; true means normal operation, false means halted.
#   "trading_halt_reason" – Optional String describing why trading was halted.
#
# All order-placement code (FuturesExecutor, Trading::CoinbasePositions, etc.)
# should call TradingHalt.active? before submitting any order. Rake tasks and
# the CLI surface halt/resume/status via TradingHalt directly.
#
# The cache keys use a long TTL so a restart does not silently re-enable trading
# after an operator-triggered halt. Set TRADING_HALT_TTL_HOURS env var to
# override (default 24 hours).
class TradingHalt
  CACHE_KEY_ACTIVE = "trading_active"
  CACHE_KEY_REASON = "trading_halt_reason"
  DEFAULT_TTL_HOURS = 24

  HaltedError = Class.new(StandardError)

  # Returns true when trading is enabled (default state).
  def self.active?
    new.active?
  end

  # Returns true when trading is halted.
  def self.halted?
    !active?
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
    return if active?

    reason = Rails.cache.read(CACHE_KEY_REASON)
    msg = "Trading is halted"
    msg += " (#{reason})" if reason.present?
    msg += " [#{context}]" if context.present?
    raise HaltedError, msg
  end

  def initialize(logger: Rails.logger, cache: Rails.cache)
    @logger = logger
    @cache = cache
  end

  def active?
    val = @cache.read(CACHE_KEY_ACTIVE)
    val.nil? || val
  end

  def halted?
    !active?
  end

  def halt!(reason: nil)
    @cache.write(CACHE_KEY_ACTIVE, false, expires_in: ttl)
    @cache.write(CACHE_KEY_REASON, reason.to_s.presence, expires_in: ttl)
    @logger.warn("[TradingHalt] Trading HALTED#{": #{reason}" if reason.present?}")
    status
  end

  def resume!
    @cache.write(CACHE_KEY_ACTIVE, true, expires_in: ttl)
    @cache.delete(CACHE_KEY_REASON)
    @logger.info("[TradingHalt] Trading RESUMED")
    status
  end

  def status
    halted = halted?
    reason = @cache.read(CACHE_KEY_REASON)
    {
      active: !halted,
      halted: halted,
      reason: reason.presence,
      as_of: Time.current.utc.iso8601
    }
  end

  private

  def ttl
    hours = (ENV["TRADING_HALT_TTL_HOURS"] || DEFAULT_TTL_HOURS).to_i
    hours.hours
  end
end
