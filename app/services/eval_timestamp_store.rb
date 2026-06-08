# frozen_string_literal: true

# Persists real-time signal evaluation recency for operator surfaces (TUI status bar).
# Dual-writes cache (fast path) and +bot_runtime_stats+ (survives dev NullStore).
class EvalTimestampStore
  CACHE_KEY = "real_time_signal_job.last_eval_at"
  DB_KEY = CACHE_KEY

  def self.write(at = Time.current.utc)
    time = at.utc
    Rails.cache.write(CACHE_KEY, time, expires_in: 10.minutes)

    stat = BotRuntimeStat.find_or_initialize_by(key: DB_KEY)
    stat.recorded_at = time
    stat.save!
  end

  def self.read
    cached = Rails.cache.read(CACHE_KEY)
    return cached if cached

    stored = BotRuntimeStat.find_by(key: DB_KEY)&.recorded_at
    return stored if stored

    SignalAlert.maximum(:alert_timestamp)
  end
end
