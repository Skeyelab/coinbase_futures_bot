# frozen_string_literal: true

# One row = the outcome of the tp/sl race started at one bar's close, in one
# direction, under one label shape (tp_frac, sl_frac, horizon). Written in
# bulk by Labels::PathDependent (issue #302 step 1).
class PathDependentLabel < ApplicationRecord
  DIRECTIONS = %w[long short].freeze
  LABELS = %w[win loss unresolved].freeze

  # Name of the unique index that defines the natural key; upserts target it.
  SHAPE_KEY_INDEX = "idx_path_dependent_labels_shape_key"

  validates :symbol, :timeframe, :bar_timestamp, :tp_frac, :sl_frac, :horizon, presence: true
  validates :direction, inclusion: {in: DIRECTIONS}
  validates :label, inclusion: {in: LABELS}
  validates :horizon, numericality: {only_integer: true, greater_than: 0}

  scope :for_shape, ->(tp_frac:, sl_frac:, horizon:) {
    where(tp_frac: tp_frac, sl_frac: sl_frac, horizon: horizon)
  }
end
