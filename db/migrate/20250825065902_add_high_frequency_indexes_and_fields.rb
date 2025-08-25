class AddHighFrequencyIndexesAndFields < ActiveRecord::Migration[8.0]
  def change
    # Add high-frequency tracking fields to trading_pairs
    add_column :trading_pairs, :last_price, :decimal, precision: 20, scale: 10
    add_column :trading_pairs, :last_price_updated_at, :datetime
    add_column :trading_pairs, :volume_24h, :decimal, precision: 30, scale: 10
    add_column :trading_pairs, :price_change_24h, :decimal, precision: 20, scale: 10

    # Add high-frequency tracking fields to positions  
    add_column :positions, :unrealized_pnl, :decimal, precision: 20, scale: 10
    add_column :positions, :current_price, :decimal, precision: 20, scale: 10

    # High-frequency indexes for positions
    add_index :positions, [:status, :day_trading], name: 'idx_positions_status_day_trading'
    add_index :positions, [:day_trading, :entry_time], name: 'idx_positions_day_trading_entry_time'
    add_index :positions, [:product_id, :status], name: 'idx_positions_product_status'
    add_index :positions, :entry_time, name: 'idx_positions_entry_time'
    add_index :positions, :close_time, name: 'idx_positions_close_time'
    add_index :positions, [:status, :entry_time], name: 'idx_positions_status_entry_time'
    
    # High-frequency indexes for candles
    add_index :candles, [:symbol, :timeframe], name: 'idx_candles_symbol_timeframe'
    add_index :candles, :timestamp, name: 'idx_candles_timestamp'
    add_index :candles, [:timeframe, :timestamp], name: 'idx_candles_timeframe_timestamp'
    
    # High-frequency indexes for trading_pairs
    add_index :trading_pairs, :last_price_updated_at, name: 'idx_trading_pairs_last_price_updated'
    add_index :trading_pairs, [:enabled, :last_price_updated_at], name: 'idx_trading_pairs_enabled_price_updated'
    
    # High-frequency indexes for good_jobs (job processing optimization)
    add_index :good_jobs, [:queue_name, :priority, :scheduled_at], 
              where: "(finished_at IS NULL)", 
              name: 'idx_good_jobs_queue_priority_scheduled'
    
    # Partial indexes for high-frequency queries
    add_index :positions, [:day_trading, :status], 
              where: "(day_trading = true AND status = 'OPEN')",
              name: 'idx_positions_open_day_trading'
              
    add_index :candles, [:symbol, :timeframe, :timestamp],
              where: "(timeframe IN ('1m', '5m'))",
              name: 'idx_candles_hf_timeframes'
  end
end
