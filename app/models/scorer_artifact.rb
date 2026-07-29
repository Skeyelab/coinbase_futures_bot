# frozen_string_literal: true

# A fitted scorer, frozen (issue #302 steps 3-4). One row carries everything
# needed to reproduce its scores forever: coefficients, the feature spec
# (names, symbol dummies, standardization constants, extractor config), and
# the training metadata that justified freezing it.
#
# Immutability is the point, not a nicety: #376 gate 2 requires samples
# gathered under a config that has stopped moving, and #483 exists because a
# nightly job silently violated exactly that. Once frozen_at is stamped the
# row refuses updates AND destroys at the model layer — a new fit is a new
# version, never an edit.
class ScorerArtifact < ApplicationRecord
  DIRECTIONS = %w[long short].freeze

  validates :version, presence: true, uniqueness: true
  validates :kind, :timeframe, presence: true
  validates :direction, inclusion: {in: DIRECTIONS}
  validates :tp_frac, :sl_frac, presence: true, numericality: {greater_than: 0}
  validates :horizon, presence: true, numericality: {only_integer: true, greater_than: 0}

  before_update :refuse_mutation_when_frozen
  before_destroy :refuse_mutation_when_frozen

  scope :frozen_artifacts, -> { where.not(frozen_at: nil) }

  # Named to avoid Object#frozen?, which is about the Ruby object.
  def frozen_artifact?
    frozen_at.present?
  end

  def freeze_artifact!
    raise ActiveRecord::ReadOnlyRecord, "artifact #{version} is already frozen" if frozen_artifact?

    update!(frozen_at: Time.current)
    self
  end

  private

  # frozen_at_was (not frozen_at) so the freezing update itself — nil -> now —
  # passes, and everything after it is refused.
  def refuse_mutation_when_frozen
    return if frozen_at_was.blank?

    raise ActiveRecord::ReadOnlyRecord,
      "artifact #{version} is frozen (#483 discipline) — fit a new version instead of mutating this one"
  end
end
