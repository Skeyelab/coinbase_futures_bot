# frozen_string_literal: true

# Captures perp funding rates before each hourly funding timestamp (issue #391).
# Runs on its own cron rather than inside FetchCandlesJob so that (a) it fires
# close to the funding boundary, where the advertised rate is nearest to what
# actually settles, and (b) a candle-backfill failure can never cost us a
# funding observation we can't get back.
class FundingRateSnapshotJob < ApplicationJob
  queue_as :default

  # Failures deliberately propagate: ApplicationJob reports them to Sentry and
  # re-raises. Swallowing one would be worse than a loud failure, because funding
  # history cannot be backfilled — a silently-skipped hour is permanent data loss.
  def perform
    MarketData::FundingRateSnapshot.call
  end
end
