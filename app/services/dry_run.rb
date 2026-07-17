# frozen_string_literal: true

# DryRun is the durable, cross-process toggle for simulated ("dry-run") trading.
# When active, the live executor routes order flow through the paper simulator
# (PaperTrading::ExchangeSimulator) instead of Coinbase, using real market data.
#
# State is persisted in the +bot_runtime_stats+ table under STORE_KEY (the same
# durable pattern as TradingHalt), so it is shared across every process (CLI,
# TUI, jobs) and survives a restart.
#
# Unlike TradingHalt, dry-run has NO auto-expiry: it must never silently flip
# back to live execution. It stays on until explicitly disabled. Default is off
# (live), preserving existing behavior.
class DryRun
  STORE_KEY = "dry_run"

  # Returns true when order flow is being simulated.
  def self.active?
    new.active?
  end

  def self.enable!(logger: Rails.logger)
    new(logger: logger).enable!
  end

  def self.disable!(logger: Rails.logger)
    new(logger: logger).disable!
  end

  def self.status
    new.status
  end

  def initialize(logger: Rails.logger)
    @logger = logger
  end

  def active?
    record = read_record
    return false if record.nil?

    !!(record.value || {})["enabled"]
  end

  def enable!
    write_state(enabled: true)
    @logger.warn("[DryRun] DRY-RUN enabled — order flow routed to the paper simulator, not Coinbase")
    status
  end

  def disable!
    write_state(enabled: false)
    @logger.warn("[DryRun] DRY-RUN disabled — LIVE execution restored")
    status
  end

  def status
    {
      active: active?,
      as_of: Time.current.utc.iso8601
    }
  end

  private

  def read_record
    BotRuntimeStat.find_by(key: STORE_KEY)
  end

  def write_state(enabled:)
    record = BotRuntimeStat.find_or_initialize_by(key: STORE_KEY)
    record.value = {"enabled" => enabled}
    record.recorded_at = Time.current.utc
    record.save!
  rescue ActiveRecord::RecordNotUnique
    retry
  end
end
