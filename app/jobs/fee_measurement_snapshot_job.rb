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

  def perform(limit: 250, now: Time.current, fee_truth: Trading::FeeTruth)
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
    report
  end

  private

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
