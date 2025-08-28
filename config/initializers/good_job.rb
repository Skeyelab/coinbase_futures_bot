GoodJob.preserve_job_records = true
GoodJob.retry_on_unhandled_error = true

Rails.application.configure do
  config.good_job.execution_mode = ENV.fetch("GOOD_JOB_EXECUTION_MODE", "async").to_sym
  config.good_job.enable_cron = true
  config.good_job.queues = ENV.fetch("GOOD_JOB_QUEUES", "default:5;critical:2;low:1")
  config.good_job.max_threads = ENV.fetch("GOOD_JOB_MAX_THREADS", 3).to_i
  config.good_job.poll_interval = ENV.fetch("GOOD_JOB_POLL_INTERVAL", 5).to_i

  config.good_job.cron = {
    candles_1h: {
      cron: ENV.fetch("CANDLES_CRON", "5 * * * *"), # at minute 5 each hour
      class: "FetchCandlesJob"
    },
    signals_15m: {
      # Run shortly after each 15m boundary to use fresh 15m candles
      # Default: minutes 1,16,31,46 of each hour
      cron: ENV.fetch("SIGNALS_CRON", "1,16,31,46 * * * *"),
      class: "GenerateSignalsJob"
    },
    paper_step: {
      cron: ENV.fetch("PAPER_CRON", "*/15 * * * *"), # every 15 minutes
      class: "PaperTradingJob"
    },
    calibrate_daily: {
      cron: ENV.fetch("CALIBRATE_CRON", "0 2 * * *"), # daily at 02:00 UTC
      class: "CalibrationJob"
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
    # Day trading position management - run every 15 minutes during trading hours
    day_trading_management: {
      cron: ENV.fetch("DAY_TRADING_MANAGEMENT_CRON", "*/15 9-16 * * 1-5"), # every 15 min, 9AM-4PM, Mon-Fri
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
      cron: ENV.fetch("HEALTH_CHECK_CRON", "0 9-17 * * 1-5"), # every hour, 9AM-5PM, Mon-Fri
      class: "HealthCheckJob"
    }
  }
end
