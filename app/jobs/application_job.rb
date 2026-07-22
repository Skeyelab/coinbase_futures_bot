class ApplicationJob < ActiveJob::Base
  # Automatically retry jobs that encountered a deadlock.
  #
  # :polynomially_longer, NOT :exponentially_longer — the latter was renamed in
  # Rails 7.1 and REMOVED in Rails 8 (this app is on 8.1). Passing it makes
  # ActiveJob raise "Couldn't determine a delay" while handling the original
  # error, so the retry machinery itself becomes the failure.
  retry_on ActiveRecord::Deadlocked, wait: :polynomially_longer, attempts: 3

  # Most jobs are safe to ignore if the underlying records are no longer available
  discard_on ActiveJob::DeserializationError

  # Global error handling with Sentry integration
  rescue_from StandardError do |error|
    # Add job context to Sentry
    Sentry.with_scope do |scope|
      scope.set_tag("job_class", self.class.name)
      scope.set_tag("job_id", job_id)
      scope.set_tag("queue_name", queue_name)
      scope.set_tag("priority", priority) if respond_to?(:priority)

      # Add job arguments as context
      scope.set_context("job_arguments", {args: arguments}) if arguments.present?

      # Add execution context
      scope.set_context("job_execution", {
        executions: executions,
        enqueued_at: enqueued_at,
        scheduled_at: scheduled_at
      })

      # Add breadcrumb for job execution
      SentryHelper.add_breadcrumb(
        message: "Job execution started",
        category: "job",
        level: "info",
        data: {
          job_class: self.class.name,
          job_id: job_id,
          queue: queue_name
        }
      )

      # Capture the exception
      Sentry.capture_exception(error)
    end

    # Log error details for local debugging
    Rails.logger.error("[#{self.class.name}] Job failed: #{error.class} - #{error.message}")
    Rails.logger.error(error.backtrace.join("\n"))

    # Re-raise to allow normal retry/discard logic
    raise error
  end

  # Add breadcrumb when job starts
  def perform(*args)
    SentryHelper.add_breadcrumb(
      message: "Job started",
      category: "job",
      level: "info",
      data: {
        job_class: self.class.name,
        job_id: job_id,
        arguments: args
      }
    )

    super
  end
end
