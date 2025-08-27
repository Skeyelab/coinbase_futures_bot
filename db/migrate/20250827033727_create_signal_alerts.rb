class CreateSignalAlerts < ActiveRecord::Migration[8.0]
  def change
    create_table :signal_alerts do |t|
      t.string :symbol
      t.string :side
      t.string :signal_type
      t.string :strategy_name
      t.decimal :confidence
      t.decimal :entry_price
      t.decimal :stop_loss
      t.decimal :take_profit
      t.integer :quantity
      t.string :timeframe
      t.string :alert_status
      t.datetime :alert_timestamp
      t.datetime :expires_at
      t.jsonb :metadata
      t.jsonb :strategy_data

      t.timestamps
    end
  end
end
