GoodJob.preserve_job_records = true
GoodJob.retry_on_unhandled_error = true

Rails.application.configure do
  config.good_job.execution_mode = ENV.fetch("GOOD_JOB_EXECUTION_MODE", "async").to_sym
  config.good_job.enable_cron = false
  config.good_job.queues = ENV.fetch("GOOD_JOB_QUEUES", "default:5;critical:2;low:1")
  config.good_job.max_threads = ENV.fetch("GOOD_JOB_MAX_THREADS", 5).to_i
  config.good_job.poll_interval = ENV.fetch("GOOD_JOB_POLL_INTERVAL", 5).to_i
end
