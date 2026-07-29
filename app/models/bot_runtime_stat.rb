# frozen_string_literal: true

class BotRuntimeStat < ApplicationRecord
  validates :key, presence: true, uniqueness: true
  validates :recorded_at, presence: true

  # Atomic whole-value write for a keyed singleton (issue #546). The
  # find_or_initialize -> save! pattern is a read-modify-write with an insert
  # race under the unique index on `key`: two connections inserting the same
  # key take conflicting index locks, and two of them in opposite order
  # deadlock — the CI flake class where a red X lands on an unrelated spec.
  # INSERT ... ON CONFLICT DO UPDATE is one statement; there is no window and
  # nothing to retry. Only for writers that overwrite their ENTIRE value —
  # read-modify-write stores (suspensions, protection locks) still need their
  # own merge logic.
  def self.upsert_value!(key:, value:, now: Time.current)
    upsert(
      {key: key, value: value, recorded_at: now.utc,
       created_at: now.utc, updated_at: now.utc},
      unique_by: :key
    )
  end
end
