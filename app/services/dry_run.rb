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
# back to live execution. It stays on until explicitly disabled — and disabling
# requires confirm: "LIVE", because restoring live execution is the most
# dangerous state change in the system.
class DryRun
  STORE_KEY = "dry_run"
  CONFIRM_PHRASE = "LIVE"

  # Raised when disable! is called without confirm: "LIVE". Restoring live
  # execution is the single most dangerous state change in the system; it does
  # not happen as a side effect of anything.
  class UnconfirmedDisable < StandardError; end

  # Returns true when order flow is being simulated.
  def self.active?
    new.active?
  end

  def self.enable!(logger: Rails.logger)
    new(logger: logger).enable!
  end

  def self.disable!(confirm: nil, reason: nil, logger: Rails.logger)
    new(logger: logger).disable!(confirm: confirm, reason: reason)
  end

  def self.status
    new.status
  end

  def initialize(logger: Rails.logger)
    @logger = logger
  end

  # FAIL CLOSED: a missing record means the state is UNKNOWN, and unknown must
  # never mean live. 2026-07-29: two real BIP orders filled minutes after a
  # service restart because absent state read as "off (live)". The only way to
  # reach live execution is an explicit, confirmed disable! that wrote a row.
  def active?
    record = read_record
    return true if record.nil?

    !!(record.value || {})["enabled"]
  end

  def enable!
    write_state(enabled: true)
    @logger.warn("[DryRun] DRY-RUN enabled — order flow routed to the paper simulator, not Coinbase")
    status
  end

  def disable!(confirm: nil, reason: nil)
    unless confirm == CONFIRM_PHRASE
      raise UnconfirmedDisable,
        "disable! requires confirm: #{CONFIRM_PHRASE.inspect} — refusing to restore live execution"
    end

    write_state(enabled: false, reason: reason)
    @logger.warn("[DryRun] DRY-RUN disabled — LIVE execution restored (reason: #{reason || "none given"})")
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

  # Every transition appends to a bounded audit trail inside the same record.
  # The 2026-07-29 forensics had exactly one timestamp to work from; the next
  # incident should read like a ledger.
  def write_state(enabled:, reason: nil)
    record = BotRuntimeStat.find_or_initialize_by(key: STORE_KEY)
    history = ((record.value || {})["history"] || []).last(19)
    history << {"enabled" => enabled, "reason" => reason, "at" => Time.current.utc.iso8601}.compact
    record.value = {"enabled" => enabled, "history" => history}
    record.recorded_at = Time.current.utc
    record.save!
  rescue ActiveRecord::RecordNotUnique
    retry
  end
end
