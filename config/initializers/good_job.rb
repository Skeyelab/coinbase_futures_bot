GoodJob.preserve_job_records = true
GoodJob.retry_on_unhandled_error = true

Rails.application.configure do
  config.good_job.execution_mode = ENV.fetch("GOOD_JOB_EXECUTION_MODE", "async").to_sym
  config.good_job.enable_cron = true
  config.good_job.queues = ENV.fetch("GOOD_JOB_QUEUES", "default:5;critical:2;low:1;realtime_signals:2")
  config.good_job.max_threads = ENV.fetch("GOOD_JOB_MAX_THREADS", 3).to_i
  config.good_job.poll_interval = ENV.fetch("GOOD_JOB_POLL_INTERVAL", 5).to_i

  # Retention for preserved job records (issue #418).
  #
  # preserve_job_records = true keeps finished executions for observability, but
  # nothing was ever pruning them. The #416/#417 retry loop turned that into
  # 964,803 rows / 3.4 GB in a single day -- 6.6x the candles table, on a disk
  # at 71%. Unbounded retention meant one misbehaving job could fill the volume.
  #
  # A rolling 7-day window keeps enough history to debug a bad night while
  # bounding worst case. Cleanup runs hourly rather than per-job so a burst
  # cannot amplify itself into cleanup churn.
  config.good_job.cleanup_preserved_jobs_before_seconds_ago =
    ENV.fetch("GOOD_JOB_RETENTION_SECONDS", 7.days.to_i).to_i
  config.good_job.cleanup_interval_seconds =
    ENV.fetch("GOOD_JOB_CLEANUP_INTERVAL_SECONDS", 1.hour.to_i).to_i

  config.good_job.cron = {
    candles_1h: {
      cron: ENV.fetch("CANDLES_CRON", "5 * * * *"), # at minute 5 each hour
      class: "FetchCandlesJob"
    },
    # Perp funding snapshot (issue #391). Funding settles hourly on the hour and
    # the API only advertises the NEXT timestamp, so the :55 reading is the
    # closest estimate of the rate that actually applies. History is not
    # reconstructible — a missed hour is gone permanently — so the earlier runs
    # are insurance, not precision: the upsert is idempotent on
    # (product_id, funding_time) and converges on the last write, which is :55.
    # One list_products call per run; redundancy is effectively free.
    funding_snapshot: {
      cron: ENV.fetch("FUNDING_SNAPSHOT_CRON", "15,30,45,55 * * * *"),
      class: "FundingRateSnapshotJob"
    },
    signals_15m: {
      # Run shortly after each 15m boundary to use fresh 15m candles
      # Default: minutes 1,16,31,46 of each hour
      cron: ENV.fetch("SIGNALS_CRON", "1,16,31,46 * * * *"),
      class: "GenerateSignalsJob"
    },
    calibrate_daily: {
      cron: ENV.fetch("CALIBRATE_CRON", "0 2 * * *"), # daily at 02:00 UTC
      class: "CalibrationJob"
    },
    symbol_circuit_breaker: {
      cron: ENV.fetch("CIRCUIT_BREAKER_CRON", "30 2 * * *"), # daily, after calibration
      class: "SymbolCircuitBreakerJob"
    },
    news_fetch: {
      cron: ENV.fetch("NEWS_FETCH_CRON", "*/2 * * * *"), # every 2 minutes
      class: "FetchNewsJob"
    },
    sentiment_fetch: {
      cron: ENV.fetch("SENTIMENT_FETCH_CRON", "*/2 * * * *"), # every 2 minutes
      class: "FetchCryptopanicJob"
    },
    sentiment_score: {
      cron: ENV.fetch("SENTIMENT_SCORE_CRON", "*/2 * * * *"), # every 2 minutes
      class: "ScoreSentimentJob"
    },
    sentiment_aggregate: {
      cron: ENV.fetch("SENTIMENT_AGG_CRON", "*/5 * * * *"), # every 5 minutes
      class: "AggregateSentimentJob"
    },
    # Sentiment predictiveness snapshot for OperatorSnapshot#indicators (#436).
    # Hourly is ample — predictiveness moves slowly (needs weeks of data).
    predictiveness_snapshot: {
      cron: ENV.fetch("PREDICTIVENESS_SNAPSHOT_CRON", "20 * * * *"), # hourly at :20
      class: "PredictivenessSnapshotJob"
    },
    # Day trading position management - run every 15 minutes during trading hours
    day_trading_management: {
      # Crypto trades 24/7 (issue #366): positions opened nights/weekends need
      # management too. Restrict via env for session-bound instruments.
      cron: ENV.fetch("DAY_TRADING_MANAGEMENT_CRON", "*/15 * * * *"),
      class: "DayTradingPositionManagementJob"
    },
    # End of day position closure - run at market close (4:00 PM ET = 8:00 PM UTC)
    end_of_day_closure: {
      cron: ENV.fetch("END_OF_DAY_CLOSURE_CRON", "0 20 * * 1-5"), # 8:00 PM UTC, Mon-Fri
      class: "EndOfDayPositionClosureJob"
    },
    # Emergency position closure - run at midnight UTC to catch any missed closures
    emergency_closure: {
      cron: ENV.fetch("EMERGENCY_CLOSURE_CRON", "0 0 * * *"), # midnight UTC daily
      class: "EndOfDayPositionClosureJob"
    },
    # Health check - run every hour during trading hours
    health_check: {
      cron: ENV.fetch("HEALTH_CHECK_CRON", "0 * * * *"), # hourly, 24/7 (issue #366)
      class: "HealthCheckJob"
    },
    # Daily paper-trading summary to Slack (Stage-2 validation tracking)
    daily_summary: {
      cron: ENV.fetch("DAILY_SUMMARY_CRON", "0 13 * * *"), # once daily, 13:00 UTC
      class: "DailySummaryJob"
    },
    # Swing position management - run every 4 hours (24/7 for overnight positions)
    swing_position_management: {
      cron: ENV.fetch("SWING_POSITION_MANAGEMENT_CRON", "0 */4 * * *"), # every 4 hours
      class: "SwingPositionManagementJob"
    },
    # Swing risk monitoring - run every 2 hours during business hours
    swing_risk_monitoring: {
      cron: ENV.fetch("SWING_RISK_MONITORING_CRON", "0 */2 9-17 * * 1-5"), # every 2 hours, 9AM-5PM, Mon-Fri
      class: "SwingRiskMonitoringJob"
    },
    # Swing position cleanup - run daily at 2 AM UTC
    swing_position_cleanup: {
      cron: ENV.fetch("SWING_POSITION_CLEANUP_CRON", "0 2 * * *"), # daily at 2 AM UTC
      class: "SwingPositionCleanupJob"
    },
    # Margin window monitoring - run every 30 minutes during market hours
    margin_window_monitoring: {
      cron: ENV.fetch("MARGIN_WINDOW_MONITORING_CRON", "*/30 9-17 * * 1-5"), # every 30 min during market hours
      class: "MarginWindowMonitoringJob"
    },
    # Contract expiry monitoring - run every 2 hours
    contract_expiry_monitoring: {
      cron: ENV.fetch("CONTRACT_EXPIRY_MONITORING_CRON", "0 */2 * * *"), # every 2 hours
      class: "ContractExpiryMonitoringJob"
    },
    # Emergency expiry check - run every hour during market hours
    emergency_expiry_check: {
      cron: ENV.fetch("EMERGENCY_EXPIRY_CHECK_CRON", "0 9-17 * * 1-5"), # every hour during market hours
      class: "ContractExpiryMonitoringJob",
      # Array-wrapped, NOT a bare Hash. GoodJob splats cron args, and
      # `Array({emergency_check: true})` yields `[[:emergency_check, true]]` --
      # an array of pairs passed as one positional argument, which raised
      # ArgumentError on every fire from 09:00 UTC (#417). Wrapping keeps it a
      # single Hash argument.
      args: [{emergency_check: true}]
    }
  }
end
