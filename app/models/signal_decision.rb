# frozen_string_literal: true

# One recorded trade-candidate evaluation (issue #480).
#
# The point is the REJECTIONS. A traded row is easy — a Position already proves
# it. What was missing was the denominator: how many candidates were considered
# and which gate stopped each one. Without that, trade frequency is
# uninterpretable and any change to selectivity is made blind.
class SignalDecision < ApplicationRecord
  TRADED = "traded"
  REJECTED = "rejected"

  belongs_to :position, optional: true

  # Reason codes. Strategy-internal reasons are prefixed so a histogram makes
  # the strategy/gate split obvious at a glance: a run dominated by
  # strategy_* is over-selective, one dominated by the rest is over-gated.
  REASONS = %w[
    traded
    symbol_suspended
    no_contract
    strategy_no_signal
    low_confidence
    protection_active
    global_position_cap
    asset_position_cap
    insufficient_buying_power
    order_failed
  ].freeze

  validates :product_id, :disposition, :reason, :evaluated_at, presence: true
  validates :disposition, inclusion: {in: [TRADED, REJECTED]}

  scope :recent, -> { order(evaluated_at: :desc) }
  scope :traded, -> { where(disposition: TRADED) }
  scope :rejected, -> { where(disposition: REJECTED) }
  scope :for_product, ->(product_id) { where(product_id: product_id) }
  scope :since, ->(time) { where(evaluated_at: time..) }

  # The query this table exists for: which gate is actually stopping trades.
  def self.rejection_histogram(product_id: nil, since: 24.hours.ago)
    scope = rejected.since(since)
    scope = scope.for_product(product_id) if product_id
    scope.group(:reason).count.sort_by { |_, count| -count }.to_h
  end

  # Evaluations that reached an order, over evaluations considered — the number
  # that makes trade frequency comparable against a backtest's.
  def self.conversion_rate(product_id: nil, since: 24.hours.ago)
    scope = since(since)
    scope = scope.for_product(product_id) if product_id
    total = scope.count
    return nil if total.zero?

    scope.traded.count.to_f / total
  end
end
