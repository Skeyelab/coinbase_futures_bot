# frozen_string_literal: true

# Heartbeat is a durable, cross-process liveness signal for the bot's long-lived
# loops (realtime signal runner, sentiment pipeline, market-data subscribers).
#
# Each loop calls +Heartbeat.beat!(name)+ on every tick; +Heartbeat.status(name)+
# reports how long ago the last beat was and whether it is stale. Because the
# realtime loop is a hand-launched foreground process with no supervisor, a
# silent death (crashed thread, dropped WebSocket) otherwise stops all position
# management while positions stay open on the exchange. A stale heartbeat makes
# that failure observable to health checks, the TUI, and the MCP control tools.
#
# State lives in +bot_runtime_stats+ under "heartbeat:<name>" — the same durable
# pattern as DryRun and TradingHalt — so it is shared across every process and
# survives a restart.
class Heartbeat
  DEFAULT_STALE_AFTER = 90 # seconds — > 2x the 30s signal-loop interval

  def self.beat!(name, now: Time.current)
    new(name).beat!(now: now)
  end

  def self.status(name, stale_after: DEFAULT_STALE_AFTER, now: Time.current)
    new(name).status(stale_after: stale_after, now: now)
  end

  def initialize(name)
    @name = name
  end

  def beat!(now: Time.current)
    record = BotRuntimeStat.find_or_initialize_by(key: store_key)
    record.value = {"last_beat_at" => now.utc.iso8601}
    record.recorded_at = now.utc
    record.save!
  rescue ActiveRecord::RecordNotUnique
    retry
  end

  def status(stale_after: DEFAULT_STALE_AFTER, now: Time.current)
    last_at = last_beat_at
    age = last_at ? (now.utc - last_at).to_i : nil

    {
      name: @name,
      last_beat_at: last_at&.utc&.iso8601,
      age_seconds: age,
      stale: last_at.nil? || age > stale_after
    }
  end

  private

  def last_beat_at
    raw = BotRuntimeStat.find_by(key: store_key)&.value&.fetch("last_beat_at", nil)
    raw && Time.iso8601(raw)
  end

  def store_key
    "heartbeat:#{@name}"
  end
end
