# frozen_string_literal: true

class CostModel
  # Taker fee per side (issue #353): momentum entries cross the spread.
  # Default ~15 bps approximates Coinbase CDE (~$0.15/side per $100-notional
  # contract); override via BACKTEST_TAKER_FEE_RATE / TAKER_FEE_RATE.
  def self.taker_fee_rate
    (ENV["BACKTEST_TAKER_FEE_RATE"] || ENV["TAKER_FEE_RATE"] || "0.0015").to_f
  end

  # Total round-trip cost in dollars: fees + slippage on both sides' notional.
  def self.round_trip_cost(entry_price:, exit_price:, quantity:, fee_rate:, slippage_rate: 0.0)
    r = fee_rate.to_f + slippage_rate.to_f
    (entry_price.to_f + exit_price.to_f) * quantity.to_f * r
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
