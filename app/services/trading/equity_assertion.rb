# frozen_string_literal: true

module Trading
  # Fails loudly when the SIZING equity diverges from the real account balance
  # (issue #482).
  #
  # SignalEquity.usd defaults to $10,000. Funding a $1,000 account with
  # SIGNAL_EQUITY_USD unset is a silent 10x oversizing on every trade — one
  # missing environment variable between the account and a margin call, with no
  # symptom until the position is already on.
  #
  # Deliberately NOT a warning. A warning is the failure mode this exists to
  # prevent: nobody reads a warning at boot, and the divergence is invisible
  # afterwards.
  module EquityAssertion
    module_function

    Divergence = Class.new(StandardError)

    def tolerance
      ENV.fetch("EQUITY_ASSERTION_TOLERANCE", "0.10").to_f
    end

    # Raises unless the sizing figure is within tolerance of actual equity.
    # Returns the two figures when they agree, so a caller can log them.
    def verify!(actual: nil, logger: Rails.logger)
      sizing = SignalEquity.usd
      actual ||= CurrentEquity.usd

      if actual.to_f <= 0
        logger.warn("[EquityAssertion] actual equity unavailable — skipping check")
        return {sizing: sizing, actual: nil, skipped: true}
      end

      drift = (sizing - actual.to_f).abs / actual.to_f
      if drift > tolerance
        raise Divergence,
          "SIGNAL_EQUITY_USD is #{format("$%.2f", sizing)} but the account holds " \
          "#{format("$%.2f", actual)} (#{(drift * 100).round(1)}% off, tolerance " \
          "#{(tolerance * 100).round}%). Every position would be sized against the " \
          "wrong figure. Set SIGNAL_EQUITY_USD to the real balance (issue #482)."
      end

      {sizing: sizing, actual: actual.to_f, drift: drift}
    end
  end
end
