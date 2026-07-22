# frozen_string_literal: true

require "rails_helper"

# Rails 8 removed the :exponentially_longer backoff symbol (renamed
# :polynomially_longer in 7.1). Passing the old name does not fail at boot or in
# the happy path -- it only raises when a retry is actually attempted, i.e.
# exactly when something has already gone wrong.
#
# On ContractExpiryMonitoringJob, which retries on StandardError, that was
# self-feeding: the "Couldn't determine a delay" RuntimeError raised while
# handling a failure is itself a StandardError, so the rule re-caught its own
# error. Result: 896,178 failed executions in 24h at ~10/sec, on the `critical`
# queue (max_threads 2), which also rate-limited Sentry and silently dropped
# unrelated error reports.
#
# This spec guards the whole job tree rather than the two known sites, because
# the failure is invisible until the worst moment.
RSpec.describe "ActiveJob retry backoff symbols" do
  # Symbols ActiveJob 8 actually understands.
  VALID_BACKOFF_SYMBOLS = %i[polynomially_longer].freeze

  it "does not use any backoff symbol removed in Rails 8, anywhere in app/jobs" do
    offenders = Dir[Rails.root.join("app/jobs/**/*.rb")].filter_map do |path|
      source = File.read(path)
      # Only flag it as a retry_on/wait: argument, not a passing mention in a comment.
      next unless source.match?(/wait:\s*:exponentially_longer/)

      Pathname.new(path).relative_path_from(Rails.root).to_s
    end

    expect(offenders).to be_empty,
      "These jobs use :exponentially_longer, removed in Rails 8. Use " \
      ":polynomially_longer instead -- it raises only when a retry fires, " \
      "so it fails precisely when you need it to work:\n  #{offenders.join("\n  ")}"
  end

  it "resolves the backoff symbol ActiveJob actually uses to a real delay" do
    # Proves :polynomially_longer is genuinely supported by this Rails version
    # rather than merely 'not the removed one'.
    determine = ActiveJob::Exceptions.instance_method(:determine_delay)

    VALID_BACKOFF_SYMBOLS.each do |sym|
      job = ContractExpiryMonitoringJob.new
      delay = determine.bind(job).call(seconds_or_duration_or_algorithm: sym, executions: 1)
      expect(delay).to be_a(Numeric), "#{sym} did not resolve to a numeric delay"
    end
  end

  it "raises for the removed symbol, proving the guard above is not vacuous" do
    determine = ActiveJob::Exceptions.instance_method(:determine_delay)
    job = ContractExpiryMonitoringJob.new

    expect {
      determine.bind(job).call(seconds_or_duration_or_algorithm: :exponentially_longer, executions: 1)
    }.to raise_error(RuntimeError, /Couldn't determine a delay/)
  end
end
