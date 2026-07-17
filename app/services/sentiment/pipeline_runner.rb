# frozen_string_literal: true

module Sentiment
  # PipelineRunner drives the sentiment collection chain (fetch -> score ->
  # aggregate) on an interval, so `bin/futuresbot start` can keep sentiment data
  # flowing without a separate Rails/GoodJob process. It mirrors
  # RealtimeSignalRunner: call start! once, then tick(now:) on a loop.
  #
  # In a deployed Rails app GoodJob cron still runs these jobs; this runner is
  # for standalone CLI/TUI sessions.
  class PipelineRunner
    DEFAULT_INTERVAL = ENV.fetch("SENTIMENT_PIPELINE_INTERVAL_SECONDS", "120").to_i

    def initialize(
      fetch_jobs: [FetchNewsJob, FetchCryptopanicJob],
      score_job: ScoreSentimentJob,
      aggregate_job: AggregateSentimentJob,
      logger: Rails.logger,
      interval_seconds: DEFAULT_INTERVAL
    )
      @fetch_jobs = fetch_jobs
      @score_job = score_job
      @aggregate_job = aggregate_job
      @logger = logger
      @interval_seconds = interval_seconds
      @last_run_at = nil
    end

    def start!
      @logger.info("[Sentiment] Starting sentiment pipeline runner (interval=#{@interval_seconds}s)...")
      run_once(Time.current.utc)
    end

    def tick(now: Time.current.utc)
      return if @last_run_at && now < @last_run_at + @interval_seconds.seconds

      run_once(now)
    end

    private

    def run_once(now)
      @last_run_at = now
      @fetch_jobs.each { |job| perform(job) }
      perform(@score_job)
      perform(@aggregate_job)
    end

    # A failing job (e.g. a flaky news source) must not kill the runner thread
    # for the rest of the session, so failures are logged and the next stage
    # still runs. @last_run_at is set before running so a persistently failing
    # job cannot spin in a tight loop.
    def perform(job)
      job.perform_now
    rescue => e
      @logger.error("[Sentiment] #{job} failed: #{e.class}: #{e.message}")
    end
  end
end
