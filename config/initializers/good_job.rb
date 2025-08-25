GoodJob.preserve_job_records = true
GoodJob.retry_on_unhandled_error = true

Rails.application.configure do
  config.good_job.execution_mode = ENV.fetch("GOOD_JOB_EXECUTION_MODE", "async").to_sym
  config.good_job.enable_cron = true
  config.good_job.queues = ENV.fetch("GOOD_JOB_QUEUES", "default:5;critical:2;low:1;high_frequency:10")
  config.good_job.max_threads = ENV.fetch("GOOD_JOB_MAX_THREADS", 10).to_i
  config.good_job.poll_interval = ENV.fetch("GOOD_JOB_POLL_INTERVAL", 1).to_i

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
    # High-frequency market data updates - every 30 seconds
    hf_market_data: {
      cron: ENV.fetch("HF_MARKET_DATA_CRON", "*/30 * * * * *"), # every 30 seconds
      class: "HighFrequencyMarketDataJob"
    },
    # High-frequency 1-minute candle updates - every minute
    hf_candles_1m: {
      cron: ENV.fetch("HF_CANDLES_1M_CRON", "0 * * * * *"), # every minute
      class: "HighFrequency1mCandleJob"
    },
    # High-frequency P&L tracking - every 15 seconds
    hf_pnl_tracking: {
      cron: ENV.fetch("HF_PNL_TRACKING_CRON", "*/15 * * * * *"), # every 15 seconds
      class: "HighFrequencyPnLTrackingJob"
    },
    # High-frequency position monitoring - every 30 seconds during trading hours
    hf_position_monitor: {
      cron: ENV.fetch("HF_POSITION_MONITOR_CRON", "*/30 * * * * *"), # every 30 seconds
      class: "HighFrequencyPositionMonitorJob"
    },
    # High-frequency signal generation - every 5 minutes for 1m/5m analysis
    hf_signals_5m: {
      cron: ENV.fetch("HF_SIGNALS_5M_CRON", "*/5 * * * *"), # every 5 minutes
      class: "HighFrequencySignalGenerationJob"
    }
  }

  # High-frequency performance optimizations
  config.good_job.max_cache = ENV.fetch("GOOD_JOB_MAX_CACHE", 1000).to_i
  config.good_job.smaller_number_is_higher_priority = true
  config.good_job.dashboard_default_locale = :en
  config.good_job.cron_timezone = 'UTC'
end
