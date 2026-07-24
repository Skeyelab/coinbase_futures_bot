# frozen_string_literal: true

module Trading
  # Compares the MODELED fees (CostModel taker/maker defaults) against the REAL
  # commissions Coinbase charged on recent fills (issue #391 fee truth). The
  # perp taker default (3 bps) is a published-schedule estimate — no perp has
  # been executed yet — so this answers "is 3 bps right?" the moment real perp
  # fills land, and flags drift via CostModel.check_taker_fee_drift!.
  #
  # Read-only. Effective bps needs the contract multiplier (perp `size` is in
  # CONTRACTS); it is resolved best-effort and its source is reported, because
  # the resolver is unreliable for some dated contracts. Per-contract commission
  # needs no multiplier and is always exact.
  class FeeTruth
    # BIP/XPP/SLP/ETP are the enabled US perps; PERP/INTX cover other venues.
    PERP_PATTERN = /\A(?:BIP|XPP|SLP|ETP)\b|PERP|INTX/i

    NOTE = "Effective bps depends on the contract multiplier (perp size is in " \
      "contracts); ContractSizeResolver is unreliable for some dated contracts, " \
      "so treat per-contract commission as ground truth and bps as approximate."

    def self.call(limit: 250, client: Trading::CoinbasePositions.new,
      resolver: Trading::ContractSizeResolver.method(:for_product), logger: Rails.logger)
      new(client: client, resolver: resolver, logger: logger).call(limit: limit)
    end

    def initialize(client:, resolver:, logger: Rails.logger)
      @client = client
      @resolver = resolver
      @logger = logger
    end

    def call(limit: 250)
      return {status: "not_authenticated"} unless @client.authenticated?

      rows = @client.list_fills(limit: limit).filter_map { |f| row(f) }
      perp = rows.select { |r| r[:perp] }

      {
        status: "ok",
        fills_examined: rows.size,
        perp_fills: perp.size,
        time_range: time_range(rows),
        model_taker_rate: CostModel.taker_fee_rate,
        model_maker_rate: CostModel.maker_fee_rate,
        by_liquidity: by_liquidity(rows),
        by_product: by_product(rows),
        perp_taker_drift: perp_taker_drift(perp),
        note: NOTE
      }
    end

    private

    def row(fill)
      contracts = fill["size"].to_f
      return nil unless contracts.positive?

      price = fill["price"].to_f
      commission = fill["commission"].to_f
      product = fill["product_id"].to_s
      multiplier = safe_multiplier(product)
      notional = (price.positive? && multiplier) ? price * contracts * multiplier : nil

      {
        product: product,
        liquidity: fill["liquidity_indicator"],
        side: fill["side"],
        trade_time: fill["trade_time"],
        commission: commission,
        commission_per_contract: commission / contracts,
        effective_rate: notional&.positive? ? commission / notional : nil,
        perp: PERP_PATTERN.match?(product)
      }
    end

    def safe_multiplier(product)
      value = @resolver.call(product)&.to_f
      value&.positive? ? value : nil
    rescue
      nil
    end

    def by_liquidity(rows)
      rows.group_by { |r| r[:liquidity] || "UNKNOWN" }.transform_values do |group|
        rated = group.filter_map { |r| r[:effective_rate] }
        {
          count: group.size,
          avg_commission_per_contract: avg(group.map { |r| r[:commission_per_contract] }),
          avg_effective_bps: rated.empty? ? nil : (avg(rated) * 10_000)
        }
      end
    end

    def by_product(rows)
      rows.group_by { |r| r[:product] }.transform_values do |group|
        {count: group.size, avg_commission_per_contract: avg(group.map { |r| r[:commission_per_contract] })}
      end
    end

    # Aggregate perp TAKER commissions into one effective rate and run the drift
    # hook (which logs on material divergence). Skipped when no perp taker fill
    # yields a reliable notional — today's reality (zero perp fills).
    def perp_taker_drift(perp_rows)
      rated = perp_rows.select { |r| r[:liquidity] == "TAKER" && r[:effective_rate] }
      return {status: "no_perp_fills"} if rated.empty?

      observed = avg(rated.map { |r| r[:effective_rate] })
      drift = CostModel.check_taker_fee_drift!(observed_rate: observed, logger: @logger)
      {
        status: drift ? "drift" : "within_tolerance",
        observed_rate: observed,
        model_rate: CostModel.taker_fee_rate,
        fills: rated.size,
        drift: drift
      }
    end

    def time_range(rows)
      times = rows.filter_map { |r| r[:trade_time] }.sort
      {from: times.first, to: times.last}
    end

    def avg(values)
      values.empty? ? 0.0 : values.sum / values.size
    end
  end
end
