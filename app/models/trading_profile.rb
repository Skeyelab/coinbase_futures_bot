# frozen_string_literal: true

# TradingProfile persists runtime risk/sizing settings as a named, versioned
# record. Exactly one profile can be active at a time. When no profile is
# active, services fall back to env-var defaults (backward-compatible).
#
# Key conventions:
#   - TradingProfile.active_profile  → the currently active record or nil
#   - profile.activate!              → make this the active profile (deactivates others)
#   - TradingProfile.effective       → active profile or a default-value struct
class TradingProfile < ApplicationRecord
  # ── Validations ───────────────────────────────────────────────────────────────

  validates :name, presence: true, uniqueness: {case_sensitive: false}

  validates :tp_target, :sl_target, :risk_fraction,
    numericality: {greater_than: 0, less_than: 1}

  validates :min_confidence_threshold,
    numericality: {greater_than_or_equal_to: 0, less_than_or_equal_to: 100}

  validates :max_position_size,
    numericality: {only_integer: true, greater_than: 0}

  validates :min_position_size,
    numericality: {only_integer: true, greater_than: 0}

  validate :min_position_size_lte_max

  validates :max_signals_per_hour,
    numericality: {only_integer: true, greater_than: 0}

  validates :deduplication_window,
    numericality: {only_integer: true, greater_than_or_equal_to: 0}

  # ── Scopes ────────────────────────────────────────────────────────────────────

  scope :active_profiles, -> { where(active: true) }

  # ── Class methods ─────────────────────────────────────────────────────────────

  # Returns the active TradingProfile for a symbol (nil symbol = the global
  # profile), or nil if none is set.
  def self.active_profile(symbol = nil)
    find_by(active: true, symbol: symbol)
  end

  # Returns a read-only value object with effective settings: the symbol's
  # active (calibrated) profile if one exists, else the active global
  # profile, else env-var / hard-coded defaults. Issue #299: calibration
  # writes per-symbol profiles that the live path reads through here.
  def self.effective(symbol: nil)
    (symbol && active_profile(symbol)) || active_profile || default_profile
  end

  # Build an unsaved, read-only record with env-var / hard-coded defaults.
  # Marked readonly! so callers cannot accidentally persist the fallback config.
  def self.default_profile
    new(
      name: "default (env)",
      tp_target: ENV.fetch("STRATEGY_TP_TARGET", "0.006").to_f,
      sl_target: ENV.fetch("STRATEGY_SL_TARGET", "0.004").to_f,
      risk_fraction: ENV.fetch("STRATEGY_RISK_FRACTION", "0.02").to_f,
      max_position_size: ENV.fetch("MAX_POSITION_SIZE", "15").to_i,
      # Default 1: the strategy floors risk-based sizing at min_position_size, so
      # a larger floor silently over-leverages small accounts / high-notional
      # contracts (a 5-contract floor is ~21x a $1k account on one GOL entry).
      min_position_size: ENV.fetch("MIN_POSITION_SIZE", "1").to_i,
      min_confidence_threshold: ENV.fetch("REALTIME_SIGNAL_MIN_CONFIDENCE", "60").to_f,
      max_signals_per_hour: ENV.fetch("REALTIME_SIGNAL_MAX_PER_HOUR", "10").to_i,
      deduplication_window: ENV.fetch("REALTIME_SIGNAL_DEDUPE_WINDOW", "300").to_i
    ).tap(&:readonly!)
  end

  # ── Instance methods ──────────────────────────────────────────────────────────

  # Make this profile active, deactivating any currently active profile FOR
  # THE SAME SYMBOL (nil symbol = the global slot). Wrapped in a transaction
  # so the swap is atomic.
  def activate!
    transaction do
      self.class.where(active: true, symbol: symbol).where.not(id: id).update_all(active: false)
      update!(active: true)
    end
    self
  end

  # Deactivate this profile without activating another.
  def deactivate!
    update!(active: false)
    self
  end

  private

  def min_position_size_lte_max
    return unless min_position_size && max_position_size
    if min_position_size > max_position_size
      errors.add(:min_position_size, "must be less than or equal to max_position_size")
    end
  end
end
