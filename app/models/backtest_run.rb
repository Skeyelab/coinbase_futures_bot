# frozen_string_literal: true

# One recorded backtest (issue #406, PRD #405).
#
# Backtests used to be write-only — the rake task printed JSON and forgot it —
# so "did this change help?" could not be answered without re-running both
# sides. A row stores the inputs as well as the outputs, because after the ADR
# 0002 venue change a set of metrics is only interpretable alongside the fee and
# sizing assumptions the run actually used.
class BacktestRun < ApplicationRecord
  KINDS = %w[single walk_forward].freeze
  STATUSES = %w[pending running succeeded failed].freeze

  # Read straight off the stored Result#to_h payload so views never dig into
  # jsonb. These are metric NAMES, not columns — adding one here is enough.
  HEADLINE_METRICS = %i[
    expectancy cost_gate_passed win_rate max_drawdown trade_count total_fees
    total_pnl final_equity sharpe_like cost_per_round_trip cost_pct_of_avg_win
  ].freeze

  validates :symbol, :step, :from_time, :to_time, presence: true
  validates :kind, inclusion: {in: KINDS}
  validates :status, inclusion: {in: STATUSES}

  scope :recent, -> { order(created_at: :desc) }
  scope :succeeded, -> { where(status: "succeeded") }
  scope :for_symbol, ->(symbol) { where(symbol: symbol) }

  # equity_curve is one entry per step — ~8,600 for a 30-day 5m window, ~43,000
  # at 1m — and trades is unbounded. Index views must not drag those across the
  # wire just to render a metrics table.
  HEAVY_COLUMNS = %w[equity_curve trades windows].freeze
  scope :without_payloads, -> { select(column_names - HEAVY_COLUMNS) }

  HEADLINE_METRICS.each do |name|
    define_method(name) { metric(name) }
  end

  STATUSES.each do |state|
    define_method(:"#{state}?") { status == state }
  end

  KINDS.each do |k|
    define_method(:"#{k}?") { kind == k }
  end

  def duration
    return nil unless started_at && finished_at

    finished_at - started_at
  end

  private

  # jsonb round-trips symbol keys as strings, but a Result#to_h assigned in the
  # same process still has symbols. Accept either so callers never have to know
  # whether the record has been through the database yet.
  def metric(name)
    return nil if metrics.blank?

    metrics.key?(name.to_s) ? metrics[name.to_s] : metrics[name.to_sym]
  end
end
