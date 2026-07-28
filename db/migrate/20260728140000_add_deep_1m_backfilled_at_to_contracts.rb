# frozen_string_literal: true

# Issue #506: the hourly cron maintains a 3-day rolling 1m window, so a newly
# ingested contract sits at three days of 1m forever while its 5m/15m/1h columns
# look healthy. 1m is what gates signal generation (MultiTimeframeSignal needs
# 60 of them), so the symbol is unusable and nothing says so.
#
# This stamp is what makes "has this contract had its deep 1m backfill" a fact
# rather than a guess. Without it, "already deep" and "genuinely thin" are
# indistinguishable, and the backfill would re-walk the whole window every hour.
class AddDeep1mBackfilledAtToContracts < ActiveRecord::Migration[8.1]
  def change
    add_column :contracts, :deep_1m_backfilled_at, :datetime

    # Partial index: the job's only question is "which enabled contracts still
    # need one", and that set shrinks to empty in steady state.
    add_index :contracts, :deep_1m_backfilled_at,
      where: "deep_1m_backfilled_at IS NULL",
      name: "index_contracts_awaiting_deep_1m_backfill"
  end
end
