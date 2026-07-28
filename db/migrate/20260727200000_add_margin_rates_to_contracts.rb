# frozen_string_literal: true

# Real per-contract margin rates, so LiquidationBuffer stops guessing.
#
# Trading::LiquidationBuffer computed liquidation from DEFAULT_LEVERAGE = 10.0
# because nothing stored real margin. That is fine while every instrument is
# ~10x, and dangerous the moment one is not: on PAU (gold perp, 5% intraday =
# 20x) the assumed-10x buffered exit fires at ~9.0% adverse while real
# liquidation is at ~4.5%. The safety rail sat BEHIND the cliff — it could not
# fire before the exchange liquidated. ADR 0004 admitted that 20x instrument
# and printed its margin in its own table without revisiting the constant.
#
# Coinbase already returns this on every products call, under
# future_product_details:
#
#   intraday_margin_rate:  {long_margin_rate:, short_margin_rate:}
#   overnight_margin_rate: {long_margin_rate:, short_margin_rate:}
#
# Two things the single-rate model missed and these columns preserve:
#
#   PER SIDE   — long and short rates differ (BIP: 0.1000185 vs 0.1000008;
#                BIT overnight: 0.234375 vs 0.289). Liquidation distance is
#                therefore side-dependent.
#   PER WINDOW — intraday is far lower than overnight (BIT: ~0.0999 vs 0.2344).
#                A LOWER rate means liquidation sits CLOSER to entry, so
#                intraday is the dangerous window and the conservative
#                assumption for a position of unknown horizon.
#
# Nullable on purpose: a contract ingested before this migration, or one whose
# payload lacks the field, must read as "unknown" so LiquidationBuffer can
# refuse to arm rather than silently fall back to a guess.
class AddMarginRatesToContracts < ActiveRecord::Migration[8.1]
  def change
    change_table :contracts, bulk: true do |t|
      t.decimal :intraday_margin_rate_long, precision: 12, scale: 8
      t.decimal :intraday_margin_rate_short, precision: 12, scale: 8
      t.decimal :overnight_margin_rate_long, precision: 12, scale: 8
      t.decimal :overnight_margin_rate_short, precision: 12, scale: 8
    end
  end
end
