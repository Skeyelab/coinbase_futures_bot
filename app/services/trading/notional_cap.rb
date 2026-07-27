# frozen_string_literal: true

module Trading
  # Account-level cap on TOTAL open notional (issue #437, #392 condition 2).
  #
  # Nothing bounded this. The existing caps bound CONTRACT COUNT, which is
  # meaningless across a mixed universe — one NOL contract is ~$930 and one BTC
  # nano ~$100, so "max 5 contracts" is two different exposures — and nothing
  # summed across concurrent positions at all.
  #
  # The gap it closes: 2% risk-based sizing at a ~40 bps stop sizes a single BIP
  # entry to ~7 contracts, roughly 4.6x a $1k account, and concurrent symbols
  # stack on top with no ceiling. On a leveraged perp venue that is the
  # difference between a drawdown and a liquidation.
  #
  # Expressed as a MULTIPLE of current equity rather than a dollar figure, so it
  # scales with the account instead of silently becoming irrelevant (or ruinous)
  # as equity moves. Measured against CurrentEquity — the balance that moves with
  # PnL — not SignalEquity, which is a fixed sizing constant (#375).
  module NotionalCap
    module_function

    DEFAULT_MULTIPLE = 2.0

    def multiple
      ENV.fetch("ACCOUNT_NOTIONAL_MULTIPLE", DEFAULT_MULTIPLE).to_f
    end

    def enabled?
      multiple.positive?
    end

    def equity_usd
      CurrentEquity.usd.to_f
    end

    def limit_usd
      equity_usd * multiple
    end

    # Summed across EVERY open position. A per-position or per-symbol check
    # cannot see the stack, which is the failure mode this exists for.
    def open_notional_usd
      Position.open.sum { |p| notional_for(p.product_id, p.size, p.entry_price) }
    end

    def room_usd
      [limit_usd - open_notional_usd, 0.0].max
    end

    def allows?(product_id:, quantity:, price:)
      return true unless enabled?
      # An unreadable balance must not stop all trading — that would be its own
      # outage. The loss caps (#482) and the halt still bound the damage.
      return true unless equity_usd.positive?

      notional_for(product_id, quantity, price) <= room_usd + Float::EPSILON
    end

    # Whole contracts the remaining room affords — for clamping a size down
    # rather than rejecting the entry outright.
    def max_quantity(product_id:, price:)
      return Float::INFINITY unless enabled?
      return Float::INFINITY unless equity_usd.positive?

      per_contract = notional_for(product_id, 1, price)
      return Float::INFINITY unless per_contract.positive?

      (room_usd / per_contract).floor
    end

    def status
      {
        enabled: enabled?,
        multiple: multiple,
        equity_usd: equity_usd.round(2),
        limit_usd: limit_usd.round(2),
        open_notional_usd: open_notional_usd.round(2),
        room_usd: room_usd.round(2)
      }
    end

    # Contract size x price x quantity.
    #
    # Deliberately does NOT special-case the resolver's DEFAULT_CONTRACT_SIZE
    # (1) fallback. A size of 1 is a legitimate value for plenty of contracts,
    # so branching on it conflates a real size with a resolution failure. And
    # when it IS a failure, price x quantity OVER-states notional for a
    # fractional contract (0.01 BTC priced as 1 BTC) — which for a cap errs
    # toward blocking, the safe direction. Erring small would let the cap be
    # breached silently.
    def notional_for(product_id, quantity, price)
      ContractSizeResolver.for_product(product_id).to_f * price.to_f * quantity.to_f
    end
  end
end
