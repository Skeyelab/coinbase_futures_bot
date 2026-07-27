# frozen_string_literal: true

class CostModel
  # AUTHORITATIVE fee model. Everything that prices a trade — the backtest
  # engine, the simulator, the #353 cost gate — resolves fees here.
  #
  # Trading::FeeTruth is NOT a second model and must not be used to price
  # anything (issue #471 asked whether the two had diverged; they had not).
  # It is a read-only observer: it compares these modeled numbers against the
  # commissions Coinbase actually charged on recent fills and flags drift via
  # check_taker_fee_drift!. CostModel decides what a trade costs; FeeTruth
  # decides whether CostModel is still telling the truth. Corrections flow
  # FeeTruth -> here (via the ENV knobs below), never the other way.

  # Taker fee per side (issue #353): momentum entries cross the spread.
  # Default ~3 bps is the US-perp taker rate (ADR 0002); the retired 15 bps
  # default was the dated-CDE number and left every un-overridden perp backtest
  # ~24 bps pessimistic per round trip (issue #391). Override via
  # BACKTEST_TAKER_FEE_RATE / TAKER_FEE_RATE.
  def self.taker_fee_rate
    (ENV["BACKTEST_TAKER_FEE_RATE"] || ENV["TAKER_FEE_RATE"] || "0.0003").to_f
  end

  # Maker fee per side. US perps charge 0% maker (ADR 0002); override via
  # BACKTEST_MAKER_FEE_RATE / MAKER_FEE_RATE.
  def self.maker_fee_rate
    (ENV["BACKTEST_MAKER_FEE_RATE"] || ENV["MAKER_FEE_RATE"] || "0.0").to_f
  end

  # Dated-futures fees (issue #458): Coinbase has NO oil/metals perp — oil trades
  # dated NOL futures whose real fee is ~$0.85/contract (measured from fills),
  # NOT the perp ~3 bps. Effective rate ~9 bps (≈ $0.85 / ~$930 notional). These
  # are seeded from observed fills; a later job (#462) auto-updates them.
  def self.dated_taker_rate
    (ENV["DATED_TAKER_RATE"] || "0.0009").to_f
  end

  def self.dated_maker_rate
    (ENV["DATED_MAKER_RATE"] || "0.0009").to_f
  end

  def self.dated_fee_per_contract
    (ENV["DATED_FEE_PER_CONTRACT"] || "0.85").to_f
  end

  # Per-venue fee params for a symbol (issue #458). A product is a PERP iff
  # Coinbase advertised funding for it (snapshotted FundingRate rows exist,
  # reusing the #457 signal); otherwise it is a dated future. Returns
  # {taker_rate:, maker_rate:, per_contract_fee:} so the engine and the cost
  # gates price each venue correctly instead of the global perp default.
  def self.fee_for(symbol)
    if perp?(symbol)
      {taker_rate: taker_fee_rate, maker_rate: maker_fee_rate, per_contract_fee: min_fee_per_contract}
    else
      {taker_rate: dated_taker_rate, maker_rate: dated_maker_rate, per_contract_fee: dated_fee_per_contract}
    end
  end

  def self.perp?(symbol)
    FundingRate.for_product(symbol.to_s).exists?
  end

  # The perp taker default (3 bps) is a published-schedule estimate — ADR 0002 /
  # issue #391 — not a measured rate: no perp fill has been executed yet. This
  # guards against it silently drifting from reality once real perp commissions
  # exist. Feed observed effective per-side taker rates (decimal, e.g. 0.0003 =
  # 3 bps) in and it returns nil when within `tolerance` (relative), or a hash
  # describing the divergence.
  #
  # TODO(#391): wire real perp commissions into check_taker_fee_drift! from the
  # deferred futuresbot fee-truth tool / historical-fills feed once perp fills
  # land. Until then this hook is inert (there is nothing real to compare).
  def self.taker_fee_drift(observed_rate:, expected_rate: taker_fee_rate, tolerance: 0.5)
    observed = observed_rate.to_f
    expected = expected_rate.to_f
    return nil if observed <= 0 || expected <= 0

    relative = (observed - expected).abs / expected
    return nil if relative <= tolerance

    {expected: expected, observed: observed, relative_drift: relative}
  end

  # Logs a warning on material taker-fee drift; returns the drift hash (or nil).
  def self.check_taker_fee_drift!(observed_rate:, expected_rate: taker_fee_rate, tolerance: 0.5, logger: Rails.logger)
    drift = taker_fee_drift(observed_rate: observed_rate, expected_rate: expected_rate, tolerance: tolerance)
    return nil unless drift

    logger&.warn(
      "[CostModel] Taker fee drift: default #{(drift[:expected] * 10_000).round(2)} bps vs observed " \
      "#{(drift[:observed] * 10_000).round(2)} bps (#{(drift[:relative_drift] * 100).round(1)}% off) — issue #391"
    )
    drift
  end

  # Funding is a position-TIME cost (issue #391), charged to open perp positions
  # at each funding timestamp crossed during the hold — never part of a fill or
  # round_trip_cost. Longs pay a positive rate; shorts collect it (and vice
  # versa when the rate is negative). Returns signed dollars: positive = cost.
  #
  # Funding timestamps are epoch-aligned multiples of `interval` (e.g. the top
  # of each hour for hourly funding). A boundary is charged when it lies in the
  # half-open window (entry_time, exit_time] — excluded at the entry instant,
  # included at the exit instant — so per-candle accrual composes without
  # double-counting.
  def self.funding_cost(notional:, side:, entry_time:, exit_time:, rate:, interval:)
    intervals = funding_intervals_crossed(entry_time: entry_time, exit_time: exit_time, interval: interval)
    return 0.0 if intervals.zero?

    direction = long_side?(side) ? 1.0 : -1.0
    direction * intervals * rate.to_f * notional.to_f
  end

  # Count epoch-aligned funding boundaries in (entry_time, exit_time].
  def self.funding_intervals_crossed(entry_time:, exit_time:, interval:)
    seconds = interval.to_i
    return 0 unless seconds.positive?

    entry_epoch = entry_time.to_i
    exit_epoch = exit_time.to_i
    return 0 if exit_epoch <= entry_epoch

    (exit_epoch / seconds) - (entry_epoch / seconds)
  end

  def self.long_side?(side)
    %i[long buy].include?(side.to_s.downcase.to_sym)
  end

  # Flat per-contract fee minimum (issue #372): Coinbase US futures charge
  # ~0.02%/contract with a $0.15/contract MINIMUM per side — the floor binds
  # whenever per-contract notional < ~$750, which makes small-notional
  # contracts (nano ETH) far more expensive than a proportional model says.
  def self.min_fee_per_contract
    ENV.fetch("TAKER_MIN_FEE_PER_CONTRACT", "0.15").to_f
  end

  # Total round-trip cost in dollars: fees + slippage on both sides' notional.
  # Pass contracts: to apply the flat per-contract floor per side, and
  # per_contract_fee: to use the VENUE's floor rather than the perp minimum
  # (issue #459 — a dated contract's floor is $0.85, not $0.15).
  def self.round_trip_cost(entry_price:, exit_price:, quantity:, fee_rate:, slippage_rate: 0.0,
    contracts: nil, per_contract_fee: nil)
    r = fee_rate.to_f + slippage_rate.to_f
    entry_side = entry_price.to_f * quantity.to_f * r
    exit_side = exit_price.to_f * quantity.to_f * r
    if contracts
      floor = contracts.to_f * (per_contract_fee || min_fee_per_contract).to_f
      entry_side = [entry_side, floor].max
      exit_side = [exit_side, floor].max
    end
    entry_side + exit_side
  end

  # Round-trip cost priced at the SYMBOL's venue (issue #459). The live gates
  # used to call round_trip_cost with the global perp rate and the perp floor,
  # which understated every dated position — oil most of all, since oil is the
  # only thing being traded and Coinbase has no oil perp.
  def self.round_trip_cost_for(symbol:, entry_price:, exit_price:, quantity:,
    slippage_rate: 0.0, contracts: nil)
    fees = fee_for(symbol)
    round_trip_cost(entry_price: entry_price, exit_price: exit_price, quantity: quantity,
      fee_rate: fees[:taker_rate], slippage_rate: slippage_rate,
      contracts: contracts, per_contract_fee: fees[:per_contract_fee])
  end

  # Per-side taker rate for a symbol, with the per-contract floor folded in.
  #
  # break_even_exit reasons in PRICES, so it cannot take a dollar floor
  # directly — but a floor is just a rate once you know what one contract is
  # worth (floor / notional). Folding it in is what lets the break-even gate
  # price the floor at all; without this it silently ignored the dominant cost
  # term on small-notional contracts. Falls back to the bare venue rate when
  # notional is unknown, which is the old behavior rather than a guess.
  def self.effective_taker_rate(symbol:, contract_notional_usd: nil)
    fees = fee_for(symbol)
    rate = fees[:taker_rate].to_f
    floor = fees[:per_contract_fee].to_f
    notional = contract_notional_usd.to_f
    return rate if notional <= 0 || floor <= 0

    [rate, floor / notional].max
  end

  # Rates per-side in decimal. Example: 0.0005 = 5 bps. funding_rate is the
  # expected funding cost over the hold as a fraction of notional (issue #391):
  # (expected_hold / interval) x rate. It widens the break-even so the ex-ante
  # gate does not approve a trade that only clears fees but then loses to
  # funding. Defaults to 0 (funding-free break-even).
  def self.break_even_exit(entry_price:, fee_rate:, slippage_rate: 0.0, funding_rate: 0.0)
    r = fee_rate.to_f + slippage_rate.to_f
    entry_price.to_f * (1.0 + r + funding_rate.to_f) / (1.0 - r)
  end

  def self.round_trip_net_pnl(entry_price:, exit_price:, quantity:, fee_rate:, slippage_rate: 0.0)
    r = fee_rate.to_f + slippage_rate.to_f
    gross = (exit_price.to_f - entry_price.to_f) * quantity.to_f
    fees = (entry_price.to_f + exit_price.to_f) * quantity.to_f * r
    gross - fees
  end
end
