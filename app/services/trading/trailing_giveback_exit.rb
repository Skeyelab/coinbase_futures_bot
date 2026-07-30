# frozen_string_literal: true

module Trading
  # TrailingGivebackExit. Arm once net profit per contract clears a threshold, then
  # exit on giving back a fraction of the peak. Unarmed, a flat per-contract stop is
  # the only exit.
  #
  # Ported from the n8n workflow the operator had been running outside this bot; see
  # docs/plans/2026-07-29-trailing-profit-giveback-exit-design.md for the rule and
  # the defects found in that workflow.
  #
  # Thresholds are PER CONTRACT and the caller passes PnL already net of the
  # round-trip fee. Both matter: on dated futures the fee is a flat per-contract
  # charge (~$0.85/side on NOL), so a fixed TOTAL dollar target decays to nothing as
  # size grows — a $10 total target nets negative by six oil contracts.
  #
  # Pure decision function. The caller owns peak tracking, which is what lets the
  # live path and a backtest share one rule.
  #
  # Not to be confused with Trading::TrailingStop, which trails a percentage of
  # PRICE. This trails a fraction of dollar profit.
  class TrailingGivebackExit
    # Config lives under real_time_signals[:trailing_giveback]. Flat keys, one
    # threshold set for every symbol — per-symbol overrides were deliberately
    # deferred until the backtest shows whether one set actually serves instruments
    # whose notionals differ ($25/contract is 2.50% on BIT, 3.79% on BIP).
    def self.from_config
      cfg = Rails.application.config.try(:real_time_signals)&.dig(:trailing_giveback) || {}

      new(
        arm_at: cfg[:arm_at_per_contract_usd],
        giveback: cfg[:giveback_fraction],
        hard_stop: cfg[:hard_stop_per_contract_usd]
      )
    end

    def initialize(arm_at:, giveback:, hard_stop:)
      @arm_at = arm_at
      @giveback = giveback
      @hard_stop = hard_stop
    end

    # Inert unless all three thresholds are set, matching the opt-in convention of
    # DollarExitPolicy and MinimumRoiExit. hard_stop is part of the gate because
    # exit_reason multiplies it — without the check, a config with arm + giveback
    # and no stop raises on every tick.
    #
    # The fraction is validated rather than clamped: 0 would put the floor at the
    # peak and exit on the tick it peaks, 1 would put it at $0 and hand back
    # everything. Quietly correcting either hides the mistake.
    def enabled?
      return false if @arm_at.nil? || @giveback.nil? || @hard_stop.nil?

      @giveback > 0 && @giveback < 1
    end

    # Armed and unarmed are exclusive, mirroring the workflow's if/else: once armed
    # the giveback floor sits well above the hard stop, so stacking them adds
    # nothing.
    #
    # Every uncertain input holds. A missing price or an unresolvable size must
    # never manufacture an exit.
    def exit_reason(net_pnl:, peak_net_pnl:, contracts:)
      return nil if net_pnl.nil? || peak_net_pnl.nil?
      return nil unless contracts.to_f.positive?

      if peak_net_pnl >= @arm_at * contracts
        return :trailing_giveback if net_pnl <= giveback_floor(peak_net_pnl)
      elsif net_pnl <= -(@hard_stop * contracts)
        return :trailing_hard_stop
      end

      nil
    end

    private

    # The dollar floor an armed position may not fall below. Rounded to cents
    # because these are dollars and sub-cent precision is noise — and because the
    # unrounded product misses its own boundary: 90 * (1 - 0.30) is
    # 62.99999999999999289, so a position resting exactly on a $63.00 floor would
    # not exit.
    def giveback_floor(peak_net_pnl)
      (peak_net_pnl * (1 - @giveback)).round(2)
    end
  end
end
