# frozen_string_literal: true

class AddMaxAdverseExcursionToPositions < ActiveRecord::Migration[8.1]
  def change
    # Worst (most negative) unrealized dollar PnL observed while the position was
    # open — the researcher's "tell" for a scalp strategy: how far winners went
    # underwater and how big the worst held loser was. Tracked per tick.
    add_column :positions, :max_adverse_excursion, :decimal
  end
end
