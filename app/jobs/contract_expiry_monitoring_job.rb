# frozen_string_literal: true

# Background job for monitoring contract expiry and closing positions before expiration
class ContractExpiryMonitoringJob < ApplicationJob
  include SentryServiceTracking

  queue_as :critical  # High priority for expiry management

  # Retry configuration for critical expiry monitoring.
  #
  # :polynomially_longer, NOT :exponentially_longer — removed in Rails 8 (see
  # ApplicationJob). Combined with `retry_on StandardError` it was catastrophic
  # rather than merely broken: the "Couldn't determine a delay" RuntimeError
  # raised while handling a failure is ITSELF a StandardError, so this rule
  # re-caught its own error and span at ~10 executions/second — 896k failed
  # executions in 24h, on the `critical` queue (max_threads 2).
  retry_on StandardError, wait: :polynomially_longer, attempts: 3

  # Accepts a positional options Hash as well as keywords.
  #
  # Keywords alone do not survive the trip through GoodJob cron + ActiveJob
  # serialization: cron `args` are splatted positionally and arguments are
  # round-tripped through JSON, so a keyword call arrives as a positional Hash.
  # Declaring keywords only meant `emergency_expiry_check` raised ArgumentError
  # on every fire (see #416/#417) -- and because it raised inside a critical
  # safety job, the failure was masked rather than obvious.
  def perform(options = {}, **kwargs)
    opts = normalize_options(options).merge(kwargs)
    buffer_days = opts[:buffer_days]
    emergency_check = opts.fetch(:emergency_check, false)

    logger = Rails.logger
    logger.info("Starting contract expiry monitoring job (emergency: #{emergency_check})")
    result = Trading::PositionManagement::ContractExpiryMonitoringWorkflow.new(logger: logger).call(
      buffer_days: buffer_days,
      emergency_check: emergency_check
    )
    logger.info(result.summary)
    logger.info("Contract expiry monitoring job completed successfully")
  rescue => e
    logger&.error("Contract expiry monitoring job failed: #{e.message}")
    logger&.error(e.backtrace.join("\n")) if e.backtrace

    SlackNotificationService.alert(
      "error",
      "Contract Expiry Monitoring Failed",
      "Critical job failed: #{e.message}. Manual intervention may be required."
    )

    raise # Re-raise to trigger retry mechanism
  end

  private

  # Tolerates every shape this job has actually been called with:
  #   {emergency_check: true}          keywords / a plain Hash
  #   {"emergency_check" => true}      after a JSON round-trip
  #   [[:emergency_check, true]]       what `Array(hash)` produces — the exact
  #                                    shape GoodJob built from `args: {..}`,
  #                                    and the cause of the original failure
  def normalize_options(options)
    case options
    when Hash then options.symbolize_keys
    when Array then options.to_h.symbolize_keys
    else {}
    end
  rescue TypeError, ArgumentError
    Rails.logger.warn("[ContractExpiryMonitoringJob] Unrecognized options #{options.inspect}; using defaults")
    {}
  end
end
