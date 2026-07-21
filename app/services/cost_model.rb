# frozen_string_literal: true

class CostModel
  # Taker fee per side (issue #353): momentum entries cross the spread.
  # Default ~15 bps approximates Coinbase CDE (~$0.15/side per $100-notional
  # contract); override via BACKTEST_TAKER_FEE_RATE / TAKER_FEE_RATE.
  def self.taker_fee_rate
    (ENV["BACKTEST_TAKER_FEE_RATE"] || ENV["TAKER_FEE_RATE"] || "0.0015").to_f
  end

  # Flat per-contract fee minimum (issue #372): Coinbase US futures charge
  # ~0.02%/contract with a $0.15/contract MINIMUM per side — the floor binds
  # whenever per-contract notional < ~$750, which makes small-notional
  # contracts (nano ETH) far more expensive than a proportional model says.
  def self.min_fee_per_contract
    ENV.fetch("TAKER_MIN_FEE_PER_CONTRACT", "0.15").to_f
  end

  # Total round-trip cost in dollars: fees + slippage on both sides' notional.
  # Pass contracts: to apply the flat per-contract floor per side.
  def self.round_trip_cost(entry_price:, exit_price:, quantity:, fee_rate:, slippage_rate: 0.0, contracts: nil)
    r = fee_rate.to_f + slippage_rate.to_f
    entry_side = entry_price.to_f * quantity.to_f * r
    exit_side = exit_price.to_f * quantity.to_f * r
    if contracts
      floor = contracts.to_f * min_fee_per_contract
      entry_side = [entry_side, floor].max
      exit_side = [exit_side, floor].max
    end
    entry_side + exit_side
  end

  # Rates per-side in decimal. Example: 0.0005 = 5 bps
  def self.break_even_exit(entry_price:, fee_rate:, slippage_rate: 0.0)
    r = fee_rate.to_f + slippage_rate.to_f
    entry_price.to_f * (1.0 + r) / (1.0 - r)
  end

  def self.round_trip_net_pnl(entry_price:, exit_price:, quantity:, fee_rate:, slippage_rate: 0.0)
    r = fee_rate.to_f + slippage_rate.to_f
    gross = (exit_price.to_f - entry_price.to_f) * quantity.to_f
    fees = (entry_price.to_f + exit_price.to_f) * quantity.to_f * r
    gross - fees
  end
end
