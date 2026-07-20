# frozen_string_literal: true

class RealtimeSignalRunner
  def initialize(job_class: RealTimeSignalJob, logger: Rails.logger, interval_seconds: 30)
    @job_class = job_class
    @logger = logger
    @interval_seconds = interval_seconds
    @last_run_at = nil
  end

  def start!
    @logger.info("[RTS] Starting real-time signal evaluation (interval=#{@interval_seconds}s)...")
    run_once(Time.current.utc)
  end

  def tick(now: Time.current.utc)
    return if @last_run_at && now < @last_run_at + @interval_seconds.seconds

    run_once(now)
  end

  private

  def run_once(now)
    @job_class.perform_now
    @last_run_at = now
    Heartbeat.beat!("realtime_signal", now: now)
  end
end
