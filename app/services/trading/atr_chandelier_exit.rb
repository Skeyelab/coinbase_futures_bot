# frozen_string_literal: true

module Trading
  # AtrChandelierExit. A stop that trails the peak by a multiple of ATR, floored
  # by an absolute dollar stop, ratcheting upward only.
  #
  # Ported from the n8n CB Watcher - Multi Position workflow the operator runs
  # outside this bot, so the backtest measures the rule actually in use. It
  # replaced the earlier profit-giveback rule, which was backtested and rejected
  # (see docs/plans/2026-07-29-trailing-profit-giveback-exit-design.md).
  #
  # Pure decision function. The caller owns peak tracking and persists the
  # returned stop, which is what lets the live path and the backtest share one
  # rule.
  #
  # Thresholds are in DOLLARS OF PnL, and the ATR term is converted from price
  # units by contract_size x contracts. Note the asymmetry this creates, which
  # the backtest is meant to expose: the trail scales with size but fixed_stop
  # does NOT, so the floor dominates at small size and becomes irrelevant at
  # large size. That is the same flaw the giveback design deliberately fixed by
  # making its thresholds per contract.
  class AtrChandelierExit
    def initialize(trail_atr:, fixed_stop:)
      @trail_atr = trail_atr
      @fixed_stop = fixed_stop
    end

    def enabled?
      !@trail_atr.nil? && !@fixed_stop.nil? && @trail_atr.to_f.positive?
    end

    # Returns the ratcheted stop, why it fired (or nil), and which rule produced
    # it. The caller persists :stop and hands it back as stored_stop next tick.
    def evaluate(net_pnl:, peak_net_pnl:, atr:, contract_size:, contracts:, stored_stop: nil)
      atr_pnl = usable_atr_pnl(atr, contract_size, contracts)
      basis = atr_pnl ? :atr : :fixed_fallback

      base = atr_pnl ? [@fixed_stop, peak_net_pnl.to_f - (@trail_atr * atr_pnl)].max : @fixed_stop

      # A ratchet only means anything once the position has actually earned
      # something; before that the stored stop is from a regime we cannot vouch
      # for.
      earned = peak_net_pnl.to_f.positive?
      stop = (earned && stored_stop) ? [stored_stop.to_f, base].max : base

      reason = contracts.to_f.positive? ? reason_for(net_pnl, peak_net_pnl, stop, basis) : nil

      {stop: stop, reason: reason, basis: basis}
    end

    private

    # nil whenever the ATR cannot carry a decision. Every uncertain input must
    # widen the stop to the absolute floor, never tighten it: a missing or stale
    # volatility reading is exactly when a tightened stop would fire on noise.
    def usable_atr_pnl(atr, contract_size, contracts)
      return nil if atr.nil? || atr.to_f <= 0
      return nil unless contract_size.to_f.positive?
      return nil unless contracts.to_f.positive?

      atr.to_f * contract_size.to_f * contracts.to_f
    end

    # Uncertain inputs hold. A missing PnL must never manufacture an exit.
    def reason_for(net_pnl, peak_net_pnl, stop, basis)
      return nil if net_pnl.nil? || peak_net_pnl.nil?
      return nil if net_pnl.to_f > stop

      # Distinguishes riding the trail down from hitting the absolute floor,
      # so the backtest can report which rule actually did the work.
      (basis == :atr && stop > @fixed_stop) ? :atr_trail : :atr_floor
    end
  end
end
