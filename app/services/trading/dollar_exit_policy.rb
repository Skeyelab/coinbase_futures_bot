# frozen_string_literal: true

module Trading
  # DollarExitPolicy decides whether an open position should be closed based on
  # its *unrealized dollar PnL* (contract-size-aware, via Position#unrealized_pnl_at)
  # rather than a bps price threshold. It implements the operator's strategy of
  # exiting each position at a fixed dollar profit ($20-50) and — critically — a
  # hard dollar stop-loss to cap the downside that a take-profit-only scalp would
  # otherwise leave open (the negative-skew trap flagged in strategy review).
  #
  # Thresholds come from the environment so the feature is inert (disabled) until
  # deliberately configured, preserving the existing bps-based exit behavior:
  #   DOLLAR_PROFIT_TARGET_USD  — close when unrealized PnL >= this many dollars
  #   DOLLAR_STOP_LOSS_USD      — close when unrealized PnL <= -this many dollars
  class DollarExitPolicy
    def self.from_env
      new(
        profit_target: env_float("DOLLAR_PROFIT_TARGET_USD"),
        stop_loss: env_float("DOLLAR_STOP_LOSS_USD")
      )
    end

    def self.env_float(key)
      raw = ENV[key]
      return nil if raw.nil? || raw.strip.empty?

      Float(raw)
    rescue ArgumentError
      nil
    end

    def initialize(profit_target:, stop_loss:)
      @profit_target = profit_target
      @stop_loss = stop_loss
    end

    def enabled?
      !@profit_target.nil? || !@stop_loss.nil?
    end

    # Returns :dollar_target, :dollar_stop_loss, or nil for the given unrealized
    # dollar PnL. Each threshold only applies when it is configured.
    def exit_reason(unrealized_pnl)
      return nil if unrealized_pnl.nil?
      return :dollar_target if @profit_target && unrealized_pnl >= @profit_target
      return :dollar_stop_loss if @stop_loss && unrealized_pnl <= -@stop_loss

      nil
    end
  end
end
