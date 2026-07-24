# frozen_string_literal: true

module Trading
  # MinimumRoiExit (issue #398, ADR 0003). A time-decaying take-profit: a
  # {minutes_held => profit_ratio} schedule lowers the profit required to exit as
  # a position ages, so a stalled winner is booked before it round-trips to
  # break-even. Ported from freqtrade's minimal_roi table.
  #
  # profit_ratio is the position's unrealized PRICE return ((current-entry)/entry,
  # side-adjusted) — the same units as the strategy's tp_target/sl_target.
  #
  # Pure decision function: no DB, no clock. Inert (disabled) for an empty
  # schedule, matching the opt-in convention of DollarExitPolicy — it only ever
  # adds an earlier take-profit and never widens the stop-loss.
  class MinimumRoiExit
    # Resolve the schedule from config: a per-symbol override, else the global
    # schedule, else empty (inert). Config lives under
    # real_time_signals[:min_roi] = { schedule: {...}, per_symbol: { sym => {...} } }.
    def self.from_config(symbol: nil)
      cfg = Rails.application.config.try(:real_time_signals)&.dig(:min_roi) || {}
      schedule = cfg.dig(:per_symbol, symbol) || cfg[:schedule] || {}
      new(schedule)
    end

    def initialize(schedule = {})
      # Normalize to integer minutes => float ratio, sorted descending by minute
      # so threshold_for can pick the first (largest) key <= minutes_held.
      @rungs = schedule
        .map { |minutes, ratio| [minutes.to_i, ratio.to_f] }
        .sort_by { |minutes, _| -minutes }
    end

    def enabled?
      @rungs.any?
    end

    # The profit ratio required to exit at this age: the value of the greatest
    # scheduled minute <= minutes_held, or nil if the schedule hasn't started.
    def threshold_for(minutes_held)
      return nil if minutes_held.nil?

      _, ratio = @rungs.find { |minutes, _| minutes <= minutes_held }
      ratio
    end

    # :time_decay_roi when the (age-decayed) profit bar is met, else nil.
    def exit_reason(profit_ratio:, minutes_held:)
      return nil if profit_ratio.nil?

      threshold = threshold_for(minutes_held)
      return nil if threshold.nil?
      return :time_decay_roi if profit_ratio >= threshold

      nil
    end
  end
end
