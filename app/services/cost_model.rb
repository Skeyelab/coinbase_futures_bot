# frozen_string_literal: true

class CostModel
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