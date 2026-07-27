# frozen_string_literal: true

module Trading
  # Whether a position on this product should be treated as a DAY TRADE, i.e.
  # force-flattened by EndOfDayPositionClosureJob at the session boundary.
  #
  # This used to be one global flag (DEFAULT_DAY_TRADING, defaulting to true),
  # so everything was intraday. That constraint came from #392 condition 4 and
  # was derived for DATED metals — "margin step-ups force liquidation-timed
  # taker exits" — then inherited by every venue without being re-checked.
  #
  # It does not survive contact with a perp. A perp has no session and no roll,
  # so the stop stays live overnight and there is nothing to be flat before; the
  # only real costs of holding are funding (0.0843 bps/hr observed on BIP — ~2
  # bps a night) and the overnight margin rate (10.00% -> 24.56% on BIP, which
  # does not bind at one contract). Measured overnight behaviour is a random
  # walk (corr -0.013 between an overnight move and the next session), and
  # bracket resolution overnight is statistically indistinguishable from
  # intraday — so flattening nightly excludes 17 of every 24 hours at identical
  # quality.
  #
  # It matters now because the measured 200/120 bps configuration (#496) holds
  # ~16.6 hours on average. Forcing those flat at 20:00 UTC would truncate
  # precisely the trades the walk-forward found profitable.
  #
  # Dated contracts keep intraday treatment: session hours, overnight margin
  # step-ups and roll risk are real there, which is what #392 was actually
  # reasoning about.
  module HoldHorizon
    module_function

    # nil product => fall back to the global default rather than guess.
    def day_trading?(product_id = nil)
      return global_default if product_id.blank?

      # nil means the venue could not be determined — fall back explicitly
      # rather than letting a falsy nil read as "not a perp".
      is_perp = perp?(product_id)
      return global_default if is_perp.nil?

      !is_perp
    end

    def perp?(product_id)
      CostModel.perp?(product_id)
    rescue => e
      Rails.logger.warn("[HoldHorizon] venue lookup failed for #{product_id}: #{e.class}; " \
                        "falling back to the global default")
      nil
    end

    def global_default
      Rails.application.config.default_day_trading
    end
  end
end
