# frozen_string_literal: true

# Measures real per-contract commissions from fills and stores them per product
# (issue #462).
#
# #458 seeded ONE dated constant — $0.85/contract, measured by hand from oil
# fills — and CostModel applied it to every dated contract. #459 then carried
# that guess into the live break-even gate, the daily net-of-costs verdict, and
# the symbol circuit breaker. This replaces the guess with observation, the way
# FundingRateSnapshot does for funding.
#
# Trading::FeeTruth already reads fills and aggregates commission per contract;
# it is the measurement engine and stays read-only. This job persists what it
# found so CostModel can prefer a real number over a constant.
class FeeMeasurementSnapshotJob < ApplicationJob
  queue_as :default

  def perform(limit: 250, now: Time.current, fee_truth: Trading::FeeTruth,
    schedule: Trading::VenueFeeSchedule)
    # The published schedule first (issue #585). This is the number CostModel
    # prices with; the fill measurements below are what the venue actually
    # charged. Refreshing it here rather than on a cron of its own keeps the two
    # halves of "what does a trade cost" on the same clock — and the tier is
    # volume-based, so it does move.
    schedule.fetch!

    report = fee_truth.call(limit: limit)

    # No credentials, or no fills yet: leave the seeded constants in place
    # rather than writing a measurement of nothing.
    unless report[:status] == "ok"
      Rails.logger.info("[FeeMeasurement] skipped: #{report[:status]}")
      return report
    end

    stored = Array(report[:by_product_liquidity]).count { |m| store(m, now) }
    Rails.logger.info("[FeeMeasurement] stored #{stored} product/liquidity measurements " \
                      "from #{report[:fills_examined]} fills")
    announce_drift(report[:perp_taker_drift])
    report
  end

  private

  # FeeTruth computes this verdict on every run and this job used to discard it.
  #
  # The 3 bps perp taker default priced all 12 BIP backtest runs and ADR 0002's
  # venue decision, whose kill criterion is stated as "≤9 bps round-trip cost".
  # The first real fills came back at 10.175 bps — 239% off — and nothing said
  # so (issue #584). CostModel.check_taker_fee_drift! existed for exactly this
  # and had zero callers.
  #
  # Silence when the model still holds is deliberate. A nightly notification
  # would be muted inside a week, and then this is invisible again for a
  # different reason.
  def announce_drift(verdict)
    return unless verdict.is_a?(Hash) && verdict[:status].to_s == "drift"

    observed = verdict[:observed_rate].to_f
    fills = verdict[:fills].to_i

    # Logs the warning and returns the drift hash. Calling it here is the point:
    # the method was written to enforce this and nothing invoked it.
    CostModel.check_taker_fee_drift!(observed_rate: observed, expected_rate: verdict[:model_rate].to_f)

    SlackNotificationService.alert("error", "Perp taker fee drift", <<~DETAILS.strip)
      Modeled #{bps(verdict[:model_rate])} bps, measured #{bps(observed)} bps across #{fills} fill#{"s" unless fills == 1}.

      The modeled rate prices every backtest and cost gate. ADR 0002's kill
      criterion assumes a round-trip cost of 9 bps or less.
    DETAILS
  end

  # A verdict without its sample size invites acting on a handful of fills as
  # though it were settled. Callers get the count; they decide what it is worth.
  def bps(rate)
    (rate.to_f * 10_000).round(2)
  end

  def store(measurement, now)
    product = measurement[:product].to_s
    commission = measurement[:avg_commission_per_contract].to_f
    return false if product.blank? || !commission.positive?

    record = ProductFee.find_or_initialize_by(
      product_id: product,
      liquidity: (measurement[:liquidity].presence || "TAKER").to_s.upcase
    )
    record.commission_per_contract = commission
    # Observability only — CostModel prices off the exact per-contract number,
    # because effective bps depends on a contract multiplier that FeeTruth
    # documents as unreliable for some dated contracts.
    rate = measurement[:avg_effective_rate].to_f
    record.effective_rate = rate.positive? ? rate : nil
    record.sample_size = measurement[:count].to_i
    record.measured_at = now
    record.save!
    true
  end
end
